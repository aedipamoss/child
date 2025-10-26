#!/usr/bin/env ruby
# frozen_string_literal: true

require "yaml"
require "json"
require "pathname"
require "rubygems"

abort "Usage: #{$PROGRAM_NAME} <config-path> <rails-root>" unless ARGV.size == 2

CONFIG_PATH = Pathname.new(ARGV[0]).expand_path
RAILS_ROOT  = Pathname.new(ARGV[1]).expand_path

# --------------------------------------------------------------------
# 1. Discover Rails + Ruby compatibility
# --------------------------------------------------------------------

NUMERIC_RUBY = /\A\d+\.\d+/
DEFAULT_RUBY_CANDIDATES = %w[3.4 3.3 3.2 3.1 3.0 2.7].freeze

def rails_version
  @rails_version ||= begin
    version_file = RAILS_ROOT.join("RAILS_VERSION")
    if version_file.exist?
      Gem::Version.new(version_file.read.strip)
    else
      require RAILS_ROOT.join("railties/lib/rails/version")
      Gem::Version.new(Rails::VERSION::STRING)
    end
  rescue
    Gem::Version.new("0.0.0")
  end
end

def min_ruby_from_gemspec
  gemspec = RAILS_ROOT.join("rails.gemspec")
  if gemspec.exist? && gemspec.read =~ /required_ruby_version[^0-9]+([0-9]+\.[0-9]+)/
    Gem::Version.new(Regexp.last_match(1))
  else
    Gem::Version.new("2.7")
  end
rescue
  Gem::Version.new("2.7")
end

def max_ruby_for(rails_ver)
  case rails_ver
  when Gem::Requirement.new("< 6.1") then Gem::Version.new("2.7")
  when Gem::Requirement.new("< 8.0") then Gem::Version.new("3.3")
  else Gem::Version.new("3.5")
  end
end

def ruby_candidates_from_env
  (ENV["RAILS_CI_RUBIES"] || "")
    .split(/[ ,\n\t]+/)
    .grep(NUMERIC_RUBY)
    .map { |t| Gem::Version.new(t) }
end

def build_ruby_catalog
  min_ruby = min_ruby_from_gemspec
  max_ruby = max_ruby_for(rails_version)

  versions = (DEFAULT_RUBY_CANDIDATES + ruby_candidates_from_env.map(&:to_s))
    .uniq
    .grep(NUMERIC_RUBY)
    .map { |v| Gem::Version.new(v) }
    .select { |v| v >= min_ruby }
    .sort
    .reverse

  ruby_info = versions.map do |ver|
    soft_fail = ver > max_ruby
    { version: ver.to_s, soft_fail: soft_fail }
  end

  {
    all: ruby_info.map { _1[:version] },
    supported: ruby_info.reject { _1[:soft_fail] }.map { _1[:version] },
    default: ruby_info.reject { _1[:soft_fail] }.map { _1[:version] }.first,
    soft_fail_map: ruby_info.to_h { |e| [e[:version], e[:soft_fail]] }
  }
end

RUBY_CATALOG = build_ruby_catalog

def expand_rubies(token)
  case token
  when "all"     then RUBY_CATALOG[:supported]
  when "default" then [RUBY_CATALOG[:default]]
  when Array     then token
  else                [RUBY_CATALOG[:default]]
  end
end

# --------------------------------------------------------------------
# 2. Helpers
# --------------------------------------------------------------------

def satisfied_by_rails?(req)
  return true unless req
  Gem::Requirement.new(req).satisfied_by?(rails_version)
rescue Gem::Requirement::BadRequirementError
  warn "⚠️ invalid requirement: #{req}"
  false
end

def default_services(variant)
  if (img = variant["mysql_image"])
    { "mysql" => { "image" => img } }
  elsif variant["task"].to_s.include?("postgres")
    { "postgres" => { "image" => "postgres:alpine" } }
  else
    {}
  end
end

def expand_variant(lib, variant)
  return [] unless satisfied_by_rails?(variant["rails_version"])
  expand_rubies(variant["rubies"]).map do |ruby_ver|
    {
      "display_name" => "#{lib} (#{variant["label"]})",
      "framework" => lib,
      "variant" => variant["label"],
      "ruby" => ruby_ver,
      "task" => variant["task"].to_s,
      "repo_pre_steps" => variant["repo_pre_steps"].to_s,
      "pre_steps" => variant["pre_steps"].to_s,
      "rack_requirement" => variant["rack_requirement"].to_s,
      "mysql_image" => variant["mysql_image"].to_s,
      "mysql_prepared_statements" => variant["mysql_prepared_statements"].to_s,
      "allow_failure" => !!variant["allow_failure"] || RUBY_CATALOG[:soft_fail_map][ruby_ver],
      "services" => JSON.dump(default_services(variant))
    }
  end
end

# --------------------------------------------------------------------
# 3. Main parse logic
# --------------------------------------------------------------------

config = YAML.load_file(CONFIG_PATH, aliases: true)
frameworks = {}

(config.dig("frameworks", "entries") || []).each do |entry|
  lib = entry["lib"]
  next unless lib
  frameworks[lib] = (entry["variants"] || []).flat_map { |v| expand_variant(lib, v) }
end

# --------------------------------------------------------------------
# 4. Emit JSON for GHA
# --------------------------------------------------------------------

output = {
  frameworks: frameworks,
  ruby_supported: RUBY_CATALOG[:supported],
  ruby_default: RUBY_CATALOG[:default]
}

puts JSON.pretty_generate(output)
