# frozen_string_literal: true

require_relative "../34_worker_approval/conversation"

module WorkflowChild
  class State
    include Phronomy::WorkflowContext

    field :agent_id, type: :replace
    field :child_id, type: :replace
    field :text, type: :replace
    field :output, type: :replace
    field :child_outcome, type: :replace
    field :consumed_revision, type: :replace
    field :imports, type: :replace, default: 0
  end

  def self.definition(store)
    Phronomy::Workflow.define(State, persistence: store) do
      initial :request_child
      state :request_child
      wait_state :awaiting_child
      state :receive, action: ->(state) { state.merge(imports: state.imports + 1) }
      transition from: :request_child, to: :awaiting_child
      transition from: :awaiting_child, on: :child_completed, to: :receive
      transition from: :awaiting_child, on: :child_rejected, to: :receive
      transition from: :receive, to: :__finish__
    end
  end
end
