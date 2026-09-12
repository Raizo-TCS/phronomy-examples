# frozen_string_literal: true

require "bundler/setup"
require "rspec"

RSpec.configure do |config|
  config.disable_monkey_patching!
  config.order = :defined
end