# frozen_string_literal: true

require "json"
require_relative "handler"
require_relative "provider_fixture"

handler = NativeChild::Handler.new(WorkerApproval.stores(ARGV.fetch(0)), NativeChild.fixed_provider)
$stdout.sync = true
$stdin.each_line do |line|
  job = JSON.parse(line)
  reply = case job.fetch("op")
          when "start" then handler.start
          when "restore" then handler.restore(job.fetch("ticket"))
          when "other" then handler.other_work
          when "answer" then handler.answer(job.fetch("approved"))
          else raise ArgumentError, "unknown command"
          end
  puts JSON.generate(reply)
end
