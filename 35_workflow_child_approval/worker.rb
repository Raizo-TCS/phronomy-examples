# frozen_string_literal: true

require_relative "../34_worker_approval/worker_host"
require_relative "handler"
require_relative "delivery"

path = ARGV.fetch(0)
WorkerApproval.serve(WorkflowChild::DispatchInbox.new(path), WorkflowChild::Handler.new(WorkerApproval.stores(path)))
