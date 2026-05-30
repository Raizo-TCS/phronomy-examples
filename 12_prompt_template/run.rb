#!/usr/bin/env ruby
# frozen_string_literal: true

# 12 Prompt Template
#
# Demonstrates Phronomy::Agent::Context::Instruction::PromptTemplate — named variable interpolation
# using {{variable}} placeholders in human and system templates.
#
# Part 1: Standalone template rendering with #variables and #invoke.
# Part 2: Agent::Base with a PromptTemplate as the instructions DSL,
#         injecting system prompt variables from the invoke Hash.

require_relative "../shared/llm_config"
require "phronomy"

# ---------------------------------------------------------------------------
# Part 1: Standalone PromptTemplate
# ---------------------------------------------------------------------------
puts "=== PromptTemplate Example ==="
puts

tmpl = Phronomy::Agent::Context::Instruction::PromptTemplate.new(
  template: "Translate the following text to {{language}}: {{text}}",
  system_template: "You are a professional {{language}} translator. Reply with only the translated text."
)

puts "Variables:    #{tmpl.variables.inspect}"
puts

rendered = tmpl.invoke({language: "French", text: "Hello, World!"})
puts "Human prompt: #{rendered[:prompt]}"
puts "System msg:   #{rendered[:system]}"
puts

# ---------------------------------------------------------------------------
# Part 2: Agent with PromptTemplate as instructions
# ---------------------------------------------------------------------------
puts "--- Agent with PromptTemplate instructions ---"
puts

translator_prompt = Phronomy::Agent::Context::Instruction::PromptTemplate.new(
  template: "Translate this text: {{text}}",
  system_template: "You are a professional {{language}} translator. Reply with only the translated text."
)

class TranslatorAgent < Phronomy::Agent::Base
  model LLMConfig::MODEL
  provider LLMConfig::PROVIDER
end

TranslatorAgent.instructions(translator_prompt)

result = TranslatorAgent.new.invoke({
  language: "Spanish",
  text: "Good morning, how are you?",
  message: "Good morning, how are you?"
})

puts "Translation: #{result[:output]}"
