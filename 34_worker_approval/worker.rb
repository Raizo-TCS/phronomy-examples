# frozen_string_literal: true

require_relative "worker_host"

path = ARGV.fetch(0)
WorkerApproval.serve(Inbox.new(path), WorkerApproval::Handler.new(WorkerApproval.store(path)))
