#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'yaml'
require 'pathname'
require 'rubygems'

if ARGV.length != 2
  warn "Usage: ruby #{$PROGRAM_NAME} <config-path> <rails-root>"
  exit 1
end

CONFIG_PATH = Pathname.new(ARGV[0]).expand_path
RAILS_ROOT = Pathname.new(ARGV[1]).expand_path

NUMERIC_RUBY = /\A\d+\.\d+/
DEFAULT_RUBY_CANDIDATES = %w[3.4 3.3 3.2 3.1 3.0 2.7 2.6 2.5 2.4].freeze

MYSQL_DEFAULT_IMAGE = 'mysql:latest'
POSTGRES_DEFAULT_IMAGE = 'postgres:alpine'
REDIS_DEFAULT_IMAGE = 'redis:alpine'

def mysql_health_command(image)
  normalized = image.to_s
  return 'mysql -h 127.0.0.1 -P 3306 -e \"SELECT 1;\"' if normalized.empty?

  if normalized.include?('mariadb')
    'healthcheck.sh --su-mysql --connect --innodb_initialized'
  else
    'mysql -h 127.0.0.1 -P 3306 -e \"SELECT 1;\"'
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

lint_section = config.fetch('lint')
lint_default_requirement = lint_section.delete('rails_version')
lint_default_tokens = Array(lint_section['rubies'])
lint_default_rubies = expand_ruby_tokens(lint_default_tokens, ruby_catalog)

lint_entries = lint_section.fetch('tasks').flat_map do |task|
  task_hash = task.transform_keys(&:to_s)
  task_requirement = task_hash.key?('rails_version') ? task_hash.delete('rails_version') : lint_default_requirement
  next [] unless requirement_satisfied?(task_requirement, rails_version)

  task_tokens = task_hash.key?('rubies') ? Array(task_hash['rubies']) : lint_default_tokens
  task_rubies = expand_ruby_tokens(task_tokens, ruby_catalog)
  task_rubies = lint_default_rubies if task_rubies.empty?

  task_rubies.map do |ruby_version|
    soft_fail = ruby_catalog[:soft_fail_map].fetch(ruby_version, false)
    data = {
      'ruby' => ruby_version,
      'task' => task_hash.fetch('task'),
      'command' => task_hash.fetch('command'),
      'allow_failure' => soft_fail
    }

    if task_hash.key?('working_directory') && !task_hash['working_directory'].to_s.empty?
      data['working_directory'] = task_hash['working_directory']
    end

    data
  end
end

frameworks_section = config.fetch('frameworks')
framework_section_requirement = frameworks_section.delete('rails_version')
framework_defaults = (frameworks_section['defaults'] || {}).transform_keys(&:to_s)
framework_default_requirement = framework_defaults.delete('rails_version') || framework_section_requirement
framework_defaults['allow_failure'] = !!framework_defaults.fetch('allow_failure', false)
framework_defaults['repo_pre_steps'] ||= ''
framework_defaults['framework_pre_steps'] ||= ''
framework_defaults['rack_requirement'] ||= ''
framework_defaults['variant'] ||= ''
framework_defaults['task'] ||= ''

framework_default_tokens = Array(frameworks_section['rubies'])
framework_default_rubies = expand_ruby_tokens(framework_default_tokens, ruby_catalog)

framework_entries = frameworks_section.fetch('entries').flat_map do |entry|
  entry_hash = framework_defaults.merge(entry.transform_keys(&:to_s))
  entry_requirement = entry_hash.key?('rails_version') ? entry_hash.delete('rails_version') : framework_default_requirement
  next [] unless requirement_satisfied?(entry_requirement, rails_version)

  entry_tokens = entry.key?('supported_rubies') ? Array(entry['supported_rubies']) : framework_default_tokens
  entry_hash.delete('supported_rubies')
  entry_rubies = expand_ruby_tokens(entry_tokens, ruby_catalog)
  entry_rubies = framework_default_rubies if entry_rubies.empty?

  entry_rubies.map do |ruby_version|
    data = entry_hash.dup
    data['ruby'] = ruby_version
    data['allow_failure'] = !!data.fetch('allow_failure', false) || ruby_catalog[:soft_fail_map].fetch(ruby_version, false)
    data['repo_pre_steps'] = data['repo_pre_steps'] || ''
    data['framework_pre_steps'] = data['framework_pre_steps'] || ''
    data['rack_requirement'] = data['rack_requirement'] || ''
    data['variant'] = data['variant'] || ''
    data['task'] = data['task'].nil? || data['task'].empty? ? 'test' : data['task']
    display_name = data.delete('name')
    data['display_name'] = display_name.nil? || display_name.empty? ? data['framework'] : display_name
    data['services'] = JSON.dump(framework_services(mysql_image: data['mysql_image']))
    data
  end
end

railties_section = config.fetch('railties')
railties_default_requirement = railties_section.delete('rails_version')
railties_default_tokens = Array(railties_section['rubies'])
railties_default_rubies = expand_ruby_tokens(railties_default_tokens, ruby_catalog)
default_shards = Array(railties_section['shards'])

railties_entries = railties_section.fetch('variants').flat_map do |variant|
  variant_hash = variant.transform_keys(&:to_s)
  variant_requirement = variant_hash.key?('rails_version') ? variant_hash.delete('rails_version') : railties_default_requirement
  next [] unless requirement_satisfied?(variant_requirement, rails_version)

  variant_tokens = variant_hash.key?('supported_rubies') ? Array(variant_hash.delete('supported_rubies')) : railties_default_tokens
  variant_rubies = expand_ruby_tokens(variant_tokens, ruby_catalog)
  variant_rubies = railties_default_rubies if variant_rubies.empty?
  shards = Array(variant_hash.delete('shards') || default_shards)
  total_shards = shards.length

  variant_rubies.flat_map do |ruby_version|
    shards.each_with_index.map do |shard, index|
      data = variant_hash.dup
      data['ruby'] = ruby_version
      data['shard'] = shard
      data['total_shards'] = total_shards
      data['parallel_job'] = index
      data['variant'] = data['variant'] || 'default'
      data['rack_requirement'] = data['rack_requirement'] || ''
      data['pre_steps'] = data['pre_steps'] || ''
      data['allow_failure'] = !!data.fetch('allow_failure', false) || ruby_catalog[:soft_fail_map].fetch(ruby_version, false)
      data['services'] = JSON.dump(common_services(mysql_image: data['mysql_image']))
      data
    end
  end
end

isolated_section = config.fetch('isolated')
isolated_default_requirement = isolated_section.delete('rails_version')
isolated_default_tokens = Array(isolated_section['rubies'])
isolated_default_rubies = expand_ruby_tokens(isolated_default_tokens, ruby_catalog)

isolated_entries = isolated_section.fetch('suites').flat_map do |suite|
  base = suite.transform_keys(&:to_s)
  suite_requirement = base.key?('rails_version') ? base.delete('rails_version') : isolated_default_requirement
  next [] unless requirement_satisfied?(suite_requirement, rails_version)

  suite_tokens = base.key?('rubies') ? Array(base.delete('rubies')) : isolated_default_tokens
  suite_rubies = expand_ruby_tokens(suite_tokens, ruby_catalog)
  suite_rubies = isolated_default_rubies if suite_rubies.empty?

  suite_services = base.key?('services') ? base.delete('services') : common_services(mysql_image: base['mysql_image'])

  suite_rubies.map do |ruby_version|
    data = base.dup
    data['ruby'] = ruby_version
    data['framework_label'] = data['framework_label'].nil? || data['framework_label'].empty? ? data['framework'] : data['framework_label']
    data['framework_dir'] = data['framework_dir'].nil? || data['framework_dir'].empty? ? data['framework'] : data['framework_dir']
    data['variant_label'] = data['variant_label'] || ''
    data['allow_failure'] = !!data.fetch('allow_failure', false) || ruby_catalog[:soft_fail_map].fetch(ruby_version, false)
    data['services'] = JSON.dump(suite_services)
    data
  end
end

outputs = {
  'lint-matrix' => { 'include' => lint_entries },
  'frameworks-matrix' => { 'include' => framework_entries },
  'railties-matrix' => { 'include' => railties_entries },
  'isolated-matrix' => { 'include' => isolated_entries },
  'ruby-default' => default_ruby,
  'ruby-supported' => ruby_catalog[:supported]
}

output_path = ENV['GITHUB_OUTPUT']
abort 'GITHUB_OUTPUT environment variable is not set.' if output_path.nil? || output_path.empty?

File.open(output_path, 'a') do |file|
  outputs.each do |key, value|
    serialized = value.is_a?(String) ? value : JSON.dump(value)
    file.puts("#{key}=#{serialized}")
  end
end
