#!/usr/bin/env ruby
# frozen_string_literal: true

require "yaml"
require "json"
require "pathname"
require "rubygems"

CONFIG_PATH = Pathname.new(ARGV[0]).expand_path
RAILS_ROOT = Pathname.new(ARGV[1]).expand_path

NUMERIC_RUBY = /\A\d+\.\d+/
DEFAULT_RUBY_CANDIDATES = %w[3.4 3.3 3.2 3.1 3.0 2.7 2.6 2.5 2.4].freeze

MYSQL_DEFAULT_IMAGE = 'mysql:latest'
POSTGRES_DEFAULT_IMAGE = 'postgres:alpine'
REDIS_DEFAULT_IMAGE = 'redis:alpine'

def mysql_health_command(image)
  normalized = image.to_s
  return 'mysql -h mysql -P 3306 -e \"SELECT 1;\"' if normalized.empty?

  if normalized.include?('mariadb')
    'healthcheck.sh --su-mysql --connect --innodb_initialized'
  else
    'mysql -h mysql -P 3306 -e \"SELECT 1;\"'
  end
end

def mysql_service(image: nil)
  selected_image = image.to_s.empty? ? MYSQL_DEFAULT_IMAGE : image
  {
    'image' => selected_image,
    'env' => {
      'MYSQL_ALLOW_EMPTY_PASSWORD' => 'yes',
      'MYSQL_ROOT_HOST' => '%',
      'MYSQLD_OPTS' => '--default-storage-engine=InnoDB --skip-log-bin --character-set-server=utf8mb4 --collation-server=utf8mb4_unicode_ci'
    },
    'ports' => ['3306:3306'],
    'options' => [
      "--health-cmd=\"#{mysql_health_command(selected_image)}\"",
      '--health-interval=10s',
      '--health-timeout=5s',
      '--health-retries=5',
    ].join(' ')
  }
end

def postgres_service(image: POSTGRES_DEFAULT_IMAGE)
  {
    'image' => image,
    'env' => {
      'POSTGRES_USER' => 'postgres',
      'POSTGRES_DB' => 'postgres',
      'POSTGRES_HOST_AUTH_METHOD' => 'trust'
    },
    'ports' => ['5432:5432'],
    'options' => [
      '--health-cmd="pg_isready -U postgres"',
      '--health-interval=10s',
      '--health-timeout=5s',
      '--health-retries=5'
    ].join(' ')
  }
end

def redis_service(image: REDIS_DEFAULT_IMAGE)
  {
    'image' => image,
    'ports' => ['6379:6379'],
    'options' => [
      '--health-cmd="redis-cli ping"',
      '--health-interval=10s',
      '--health-timeout=5s',
      '--health-retries=5'
    ].join(' ')
  }
end

def common_services(mysql_image: nil)
  {
    'mysql' => mysql_service(image: mysql_image),
    'postgres' => postgres_service,
    'redis' => redis_service
  }
end

def framework_services(mysql_image: nil)
  common_services(mysql_image: mysql_image).merge(
    'memcached' => {
      'image' => 'memcached:1.6-alpine',
      'ports' => ['11211:11211']
    },
    'rabbitmq' => {
      'image' => 'rabbitmq:3.12-alpine',
      'ports' => ['5672:5672']
    },
    'beanstalkd' => {
      'image' => 'schickling/beanstalkd:latest',
      'ports' => ['11300:11300']
    }
  )
end

def env_ruby_candidates
  env = ENV.fetch('RAILS_CI_RUBIES', nil)
  return [] if env.nil? || env.strip.empty?

  env.split(/[ ,\n\t]+/).map(&:strip).reject(&:empty?)
rescue ArgumentError
  []
end

def load_config(path)
  YAML.load_file(path, aliases: true)
rescue Errno::ENOENT
  abort "Configuration file not found: #{path}"
end

def rails_root
  RAILS_ROOT
end

def rails_version
  @rails_version ||= Gem::Version.new(rails_version_file)
end

def rails_version_file
  path = rails_root.join('RAILS_VERSION')
  contents = path.read.strip
  abort "Rails version file is empty: #{path}" if contents.empty?
  contents
rescue Errno::ENOENT
  abort "Rails version file not found: #{path}"
end

def requirement_satisfied?(requirement, rails_version)
  return true if requirement.nil? || requirement.to_s.strip.empty?
  return true if rails_version.nil?

  Gem::Requirement.new(requirement).satisfied_by?(rails_version)
rescue Gem::Requirement::BadRequirementError
  warn "Ignoring invalid rails_version requirement: #{requirement}"
  false
end

config = load_config(CONFIG_PATH)

abort "Rails source directory not found: #{rails_root}" unless rails_root.directory?

min_ruby = begin
  gemspec = rails_root.join('rails.gemspec').read
  if gemspec =~ /required_ruby_version[^0-9]+([0-9]+\.[0-9]+)/
    Gem::Version.new(Regexp.last_match(1))
  else
    Gem::Version.new('2.0')
  end
rescue Errno::ENOENT
  Gem::Version.new('2.0')
end

max_ruby = if rails_version
  case rails_version
  when Gem::Requirement.new('< 6.1')
    Gem::Version.new('2.7')
  when Gem::Requirement.new('< 8')
    Gem::Version.new('3.3')
  end
end

explicit_ruby_tokens = []
explicit_ruby_tokens.concat Array(config.dig('lint', 'rubies'))
explicit_ruby_tokens.concat Array(config.dig('frameworks', 'rubies'))
config.dig('frameworks', 'entries')&.each do |entry|
  explicit_ruby_tokens.concat Array(entry['supported_rubies'])
end
explicit_ruby_tokens.concat Array(config.dig('railties', 'rubies'))
config.dig('railties', 'variants')&.each do |variant|
  explicit_ruby_tokens.concat Array(variant['supported_rubies'])
end
explicit_ruby_tokens.concat Array(config.dig('isolated', 'rubies'))
config.dig('isolated', 'suites')&.each do |suite|
  explicit_ruby_tokens.concat Array(suite['rubies'])
end

candidate_versions = []
candidate_versions.concat DEFAULT_RUBY_CANDIDATES
candidate_versions.concat env_ruby_candidates
candidate_versions.concat explicit_ruby_tokens.compact.select { |token| token.to_s.match?(NUMERIC_RUBY) }
candidate_versions << min_ruby.to_s
candidate_versions << max_ruby.to_s if max_ruby

ruby_versions = candidate_versions.compact.map(&:to_s)
  .select { |token| token.match?(NUMERIC_RUBY) }
  .map { |token| Gem::Version.new(token) }
  .select { |version| version >= min_ruby }
  .uniq { |version| version.to_s }
  .sort
  .reverse

abort 'No Ruby versions found in configuration.' if ruby_versions.empty?

ruby_info = ruby_versions.map do |version|
  recommendation = max_ruby && Gem::Requirement.new(max_ruby.approximate_recommendation)
  soft_fail = max_ruby && version > max_ruby && !(recommendation&.satisfied_by?(version))
  {
    version: version.to_s,
    soft_fail: !!soft_fail
  }
end

supported_rubies = ruby_info.reject { |entry| entry[:soft_fail] }.map { |entry| entry[:version] }
default_ruby = supported_rubies.first || ruby_info.first[:version]

ruby_soft_fail_map = ruby_info.each_with_object({}) do |entry, memo|
  memo[entry[:version]] = entry[:soft_fail]
end

ruby_catalog = {
  all: ruby_info.map { |entry| entry[:version] },
  supported: supported_rubies,
  soft_fail: ruby_info.select { |entry| entry[:soft_fail] }.map { |entry| entry[:version] },
  default: default_ruby,
  soft_fail_map: ruby_soft_fail_map
}

def expand_ruby_tokens(tokens, catalog)
  list = Array(tokens)
  list = ['default'] if list.empty?

  expanded = list.flat_map do |token|
    case token
    when nil, ''
      []
    when 'default', 'latest', 'latest-stable'
      catalog[:default] ? [catalog[:default]] : []
    when 'supported', 'stable'
      catalog[:supported]
    when 'all'
      catalog[:all]
    when 'soft-fail'
      catalog[:soft_fail]
    else
      [token]
    end
  end

  seen = {}
  expanded.each_with_object([]) do |ruby_version, acc|
    str = ruby_version.to_s
    next if str.empty?
    next if seen[str]
    seen[str] = true
    acc << str
  end
end

def shard_label(shard, total_shards)
  return "" unless total_shards.to_i > 1
  " #{shard}/#{total_shards}"
end

def expand_variant(lib, variant, catalog, total_shards: nil, shard: nil)
  rails_requirement =
    variant.key?("rails_version") ? variant.delete("rails_version") : ""
  return [] unless requirement_satisfied?(rails_requirement, rails_version)

  expand_ruby_tokens(variant["rubies"], catalog).map do |ruby_ver|
    entry = {
      display_name: "#{lib} (#{variant["label"]}) [#{ruby_ver}]#{shard_label(shard, total_shards)}",
      framework: lib,
      variant: variant["label"],
      ruby: ruby_ver,
      nodejs: variant.key?("nodejs") ? variant["nodejs"].to_s : "false",
      save_bundler_cache: variant.key?("save_bundler_cache") ? variant["save_bundler_cache"].to_s : "true",
      task: variant.key?("task") ? variant["task"].to_s : "test",
      repo_pre_steps: variant["repo_pre_steps"].to_s,
      pre_steps: variant["pre_steps"].to_s,
      rack_requirement: variant["rack_requirement"].to_s,
      mysql_image: variant["mysql_image"].to_s,
      mysql_prepared_statements: variant["mysql_prepared_statements"].to_s,
      allow_failure: !!variant["allow_failure"] || catalog[:soft_fail_map][ruby_ver],
      services: JSON.dump(framework_services(mysql_image: variant["mysql_image"]))
    }

    if total_shards > 1
      entry[:total_shards] = total_shards
      entry[:shard] = shard + 1
      entry[:parallel_job] = shard - 1
    end

    entry
  end
end

frameworks = {}

(config.dig("frameworks", "entries") || []).each do |entry|
  lib = entry["lib"]
  next unless lib

  total_shards = [entry.delete("shards").to_i, 1].max
  variants = entry["variants"] || []

  frameworks[lib] = variants.flat_map do |variant|
    (1..total_shards).flat_map do |shard|
      expand_variant(lib, variant.dup, ruby_catalog, total_shards:, shard: shard)
    end
  end
end

output = {
  "frameworks" => frameworks,
  "ruby-supported" => ruby_catalog[:supported],
  "ruby-default" => ruby_catalog[:default]
}

output_path = ENV['GITHUB_OUTPUT']
abort 'GITHUB_OUTPUT environment variable is not set.' if output_path.nil? || output_path.empty?

puts "::group::Parsed Rails CI Configuration"
puts JSON.pretty_generate(output)
puts "::endgroup::"

File.open(output_path, 'a') do |file|
  output.each do |key, value|
    serialized = value.is_a?(String) ? value : JSON.dump(value)
    file.puts("#{key}=#{serialized}")
  end
end
