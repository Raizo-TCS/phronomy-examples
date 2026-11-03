# frozen_string_literal: true

require "json"
require_relative "handler"
require_relative "provider_fixture"

handler = NativeChild::Handler.new(WorkerApproval.stores(ARGV.fetch(0)), NativeChild.fixed_provider)
$stdout.sync = true
$stdin.each_line do |line|
  job = JSON.parse(line)
  reply = case job.fetch("op")
          when "start" then handler.start(job.fetch("input", "use the child"))
          when "restore" then handler.restore(job.fetch("ticket"))
          when "other" then handler.other_work
          when "approve_and_handoff" then handler.approve_and_handoff
          when "replay" then handler.replay_approval(job.fetch("approval"))
          when "answer" then handler.answer(job.fetch("approved"))
          when "history" then handler.terminal_history(job.fetch("ids"))
          when "release" then handler.release_completed(job.fetch("ids"))
          when "next_turn" then handler.next_turn
          else raise ArgumentError, "unknown command"
          end
  puts JSON.generate(reply)
end
