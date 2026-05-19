# frozen_string_literal: true

require "pathname"

# Human-in-the-loop gate: asks the user once at startup whether agents may read
# files from the target directory. All tool calls check this approval before
# accessing the filesystem.
module DirectoryAccess
  @approved_path = nil

  # Called once at program startup, before any LLM invocations.
  # Reads from STDIN so it is always interactive regardless of execution context.
  def self.ask_user!(path)
    abs_path = File.expand_path(path)
    STDOUT.puts
    STDOUT.puts "[Human-in-the-Loop] Agents will read source files under:"
    STDOUT.puts "  #{abs_path}"
    STDOUT.print "  Allow directory access? [y/N]: "
    STDOUT.flush
    input = STDIN.gets&.chomp.to_s
    if input.downcase == "y"
      @approved_path = abs_path
      STDOUT.puts "  => Approved.\n\n"
      true
    else
      STDOUT.puts "  => Denied. Agents cannot read files.\n\n"
      false
    end
  end

  def self.approved_path
    @approved_path
  end
end

# Lists all Ruby source files in the approved directory.
# Call this first to discover which files are available for analysis.
class ListFilesTool < Phronomy::Tool::Base
  description "List all Ruby source files available for analysis. " \
              "Call this first before reading any file."

  def execute
    path = DirectoryAccess.approved_path
    return "Directory access not approved." unless path

    files = Dir.glob(File.join(path, "**", "*.rb")).sort
    return "No Ruby files found." if files.empty?

    base = Pathname.new(path)
    files.map { |f| Pathname.new(f).relative_path_from(base).to_s }.join("\n")
  end
end

# Reads the contents of a single Ruby source file.
# Pass a relative path as returned by list_files.
class ReadFileTool < Phronomy::Tool::Base
  description "Read the full contents of a Ruby source file. " \
              "Pass a relative path as returned by list_files."
  param :filename, type: :string,
                   desc: "Relative path to the file within the approved directory"

  def execute(filename:)
    path = DirectoryAccess.approved_path
    return "Directory access not approved." unless path

    # Security: resolve the full path and reject any traversal outside approved dir.
    full_path = File.expand_path(filename, path)
    real_path = File.realpath(full_path)
    unless real_path.start_with?("#{path}/") || real_path == path
      return "Access denied: path is outside the approved directory."
    end

    File.read(real_path)
  rescue Errno::ENOENT
    "File not found: #{filename}"
  rescue StandardError => e
    "Read failed: #{e.message}"
  end
end
