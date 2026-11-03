# frozen_string_literal: true

require_relative "../34_worker_approval/conversation"

module NativeChild
  class PublishRequest < Phronomy::Tool::Base
    tool_name "publish_request"
    description "Publish the approved change."
    requires_approval true

    def execute
      File.open(ENV.fetch("APPROVED_EFFECT_LOG"), "a") { |log| log.puts("published by #{Process.pid}") }
      "published"
    end
  end

  class Child < Phronomy::Agent::Base
    agent_definition id: "native-child-approval-worker", version: 1
    model "gpt-4o-mini"
    provider :openai
    tools WorkerApproval::ApplyRequest => nil, PublishRequest => nil
  end

  class Parent < Phronomy::MultiAgent::Orchestrator
    agent_definition id: "native-child-approval-parent", version: 2
    model "gpt-4o-mini"
    provider :openai
    subagent :worker, Child
  end

  def self.check(value, expected)
    raise "Expected #{expected.inspect}, got #{value.inspect}" unless value == expected
  end
end
