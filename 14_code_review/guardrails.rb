# frozen_string_literal: true

require "phronomy"

# Validates the user-supplied file path before the pipeline begins.
# Rejects empty paths, non-existent files, non-.rb files, and empty files.
class FileInputGuardrail < Phronomy::Guardrail::InputGuardrail
  def check(value)
    path = value.to_s.strip
    fail!("File path cannot be empty") if path.empty?
    fail!("File not found: #{path}") unless File.exist?(path)
    fail!("Not a Ruby file (expected .rb extension): #{path}") unless path.end_with?(".rb")
    fail!("File is empty: #{path}") if File.size(path).zero?
  end
end

# Validates that the ImproverAgent's output contains a fenced code block.
# A code block is the minimum expected format for improved Ruby code.
class CodeOutputGuardrail < Phronomy::Guardrail::OutputGuardrail
  def check(value)
    fail!("Output does not contain a code block (expected ``` fence)") unless value.to_s.include?("```")
  end
end
