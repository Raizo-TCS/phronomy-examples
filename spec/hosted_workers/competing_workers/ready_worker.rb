# frozen_string_literal: true

require_relative "../../../34_worker_approval/worker_host"

database = ARGV.fetch(0)
barrier = File.join(File.dirname(database), "tool-barrier")
if Dir.exist?(barrier)
  # Instrument the fixture only in the overlap case. Each Tool must have
  # entered a different OS process before either effect can be performed.
  WorkerApproval::ApplyRequest.prepend(Module.new do
    define_method(:execute) do
      File.write(File.join(barrier, Process.pid.to_s), "")
      Timeout.timeout(15) do
        sleep 0.02 while Dir.children(barrier).size < 2
      end
      super()
    end
  end)
end
inbox = Inbox.new(database)
handler = WorkerApproval::Handler.new(WorkerApproval.store(database))
STDOUT.sync = true
puts JSON.generate(ready: Process.pid)
WorkerApproval.serve(inbox, handler)
