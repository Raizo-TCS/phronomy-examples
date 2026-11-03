# frozen_string_literal: true

require "open3"
require "rbconfig"
require "timeout"
require "json"

module WorkerApproval
  # Pipes drive the acceptance scenario deterministically. SQLite holds every
  # accepted input, target claim and acknowledgement.
  class WorkerProcess
    attr_reader :process

    def initialize(db, effects, script: File.join(__dir__, "worker.rb"))
      @input, @output, @process = Open3.popen2({"APPROVED_EFFECT_LOG" => effects}, RbConfig.ruby,
        script, db)
    end

    def send_command(command)
      @input.puts(command)
      @input.flush
    end

    def receive
      line = Timeout.timeout(25) { @output.gets }
      raise EOFError, "worker exited before replying" unless line
      JSON.parse(line)
    end

    def stop!
      Process.kill("KILL", process.pid) if process.alive?
      process.join
    rescue Errno::ESRCH
      process.join
    end

    def close
      @input.close
      stop! unless process.join(4)
      @output.close
    end
  end
end
