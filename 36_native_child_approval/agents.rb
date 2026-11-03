# frozen_string_literal: true

require_relative "../34_worker_approval/conversation"

module NativeChild
  class Parent < Phronomy::MultiAgent::Orchestrator
    agent_definition id: "native-child-approval-parent", version: 1
    model "gpt-4o-mini"
    provider :openai
    subagent :worker, WorkerApproval::Conversation
  end

  def self.check(value, expected)
    raise "Expected #{expected.inspect}, got #{value.inspect}" unless value == expected
  end
end
