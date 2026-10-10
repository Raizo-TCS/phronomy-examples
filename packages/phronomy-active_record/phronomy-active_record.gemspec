# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name = "phronomy-active_record"
  spec.version = "0.1.0"
  spec.summary = "Optional ActiveRecord persistence for Phronomy"
  spec.authors = ["Phronomy contributors"]
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2"
  spec.files = Dir["lib/**/*.rb", "db/**/*.rb", "README.md"]
  spec.require_paths = ["lib"]
  spec.add_dependency "phronomy", "~> 0.28.0"
  spec.add_dependency "activerecord", ">= 7.1", "< 9"
end
