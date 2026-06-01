# frozen_string_literal: true

require "phronomy"

# Reads the contents of a Ruby source file from disk.
# Used inside an Agent to fetch source code on demand.
class FileReadTool < Phronomy::Agent::Context::Capability::Base
  description "Read the contents of a Ruby source file from disk"
  param :file_path, type: :string, desc: "Absolute or relative path to the Ruby source file"

  def execute(file_path:)
    File.read(file_path)
  rescue Errno::ENOENT
    "Error: file not found — #{file_path}"
  rescue => e
    "Error reading file: #{e.message}"
  end
end
