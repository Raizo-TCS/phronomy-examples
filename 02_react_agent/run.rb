#!/usr/bin/env ruby
# frozen_string_literal: true

# 02 ReAct Agent
#
# Demonstrates a ReAct-style agent with custom tools.
# CityInfoAgent uses GetCurrentTimeTool and GetWeatherTool to answer
# questions about a city's current time and weather.

require_relative "../shared/llm_config"
require "phronomy"
require_relative "tools"

class CityInfoAgent < Phronomy::Agent::Base
  model LLMConfig::MODEL
  provider LLMConfig::PROVIDER
  instructions "You are a city information assistant. " \
               "Use the tools to look up the current time and weather for a given city " \
               "and report back to the user concisely."
  tools GetCurrentTimeTool, GetWeatherTool
end

query = "What is the current time and weather in Tokyo?"

puts "=== ReAct Agent Example ==="
puts "Query: #{query}"
puts
puts "--- Agent Response ---"

result = CityInfoAgent.new.invoke(query)
puts result[:output]
