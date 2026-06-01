# frozen_string_literal: true

require "phronomy"

# Dummy tool: returns a fixed current time for the given city.
class GetCurrentTimeTool < Phronomy::Agent::Context::Capability::Base
  description "Returns the current time for the given city."
  param :city, type: :string, desc: "City name (e.g. Tokyo)"

  def execute(city:)
    "The current time in #{city} is 10:00 JST (2026-05-06)."
  end
end

# Dummy tool: returns a fixed weather for the given city.
class GetWeatherTool < Phronomy::Agent::Context::Capability::Base
  description "Returns the current weather for the given city."
  param :city, type: :string, desc: "City name (e.g. Tokyo)"

  def execute(city:)
    "The weather in #{city} is Sunny, 22°C."
  end
end
