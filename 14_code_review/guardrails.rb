# frozen_string_literal: true

require "phronomy"

# Validates the user-supplied file path before the pipeline begins.
# Rejects empty paths, non-existent files, non-.rb files, and empty files.
class FileInputGuardrail < Phronomy::Filter::Base
  def call(value, **_context)
    path = value.to_s.strip
    block!("File path cannot be empty") if path.empty?
    block!("File not found: #{path}") unless File.exist?(path)
    block!("Not a Ruby file (expected .rb extension): #{path}") unless path.end_with?(".rb")
    block!("File is empty: #{path}") if File.size(path).zero?
    value
  end
end

# Validates that the ImproverAgent's output contains a fenced code block.
# A code block is the minimum expected format for improved Ruby code.
class CodeOutputGuardrail < Phronomy::Filter::Base
  def call(value, **_context)
    block!("Output does not contain a code block (expected ``` fence)") unless value.to_s.include?("```")
    value
  end
end
