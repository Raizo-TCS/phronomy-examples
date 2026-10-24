# frozen_string_literal: true

require_relative "../spec/spec_helper"

# Confirmed durable facts and new-pool readability. The HTTP provider is stubbed;
# these tests do not claim an external-side-effect exactly-once guarantee.
RSpec.shared_examples "persisted structured output" do
  let(:output_schema) { {type: "object", properties: {answer: {type: "string"}}, required: ["answer"], additionalProperties: false} }
  let(:structured_agent) do
    Class.new(Phronomy::Agent::Base) do
      agent_definition id: "sql-structured-output", version: 1
      model "gpt-4o-mini"
      provider :openai
    end
  end

  def reopen_structured_storage
    Phronomy.reset_runtime!
    initial_storage.fetch(1).disconnect!
    stores, pool = reopened_storage
    expect(pool).not_to equal(initial_storage.fetch(1))
    stores
  end

  %i[native none].each do |delivery|
    [true, false].each do |valid|
      it "preserves structured #{valid ? 'success' : 'failure'} without LLM replay after a fresh pool with #{delivery} delivery" do
        chat = ExampleChatStub.new { valid ? '{"answer":"saved"}' : 'malformed output' }
        store = initial_storage.fetch(0).agent
        agent = structured_agent.create(persistence: store)
        id = nil
        if valid
          result = agent.invoke("question", output_schema: output_schema, schema_delivery: delivery)
          id = result.fetch(:execution_id)
          expect(result[:output]).to eq("answer" => "saved")
        else
          expect { agent.invoke("question", output_schema: output_schema, schema_delivery: delivery) }.to raise_error(Phronomy::Agent::OutputError) { |error| id = error.execution_id }
        end
        before = store.executions.load(id)
        restored = reopen_structured_storage
        loaded = structured_agent.load(agent.agent_id, persistence: restored.agent)
        if valid
          value = loaded.resume(id)
          expect(value[:output]).to eq("answer" => "saved")
          expect(value[:output]).to be_frozen
          expect(value[:raw_output]).to eq('{"answer":"saved"}')
          expect(loaded.transcript_messages.map(&:to_h)).to eq(result[:messages].map(&:to_h))
          expect(loaded.transcript_messages_async.wait_result.map(&:to_h)).to eq(result[:messages].map(&:to_h))
        else
          expect { loaded.resume(id) }.to raise_error(Phronomy::Agent::OutputError) { |error|
            expect(error.reason).to eq("invalid_json")
            expect(error.raw_output).to eq("malformed output")
            expect(error.cause.code).to eq("output_parser.invalid_json")
          }
        end
        expect(restored.agent.executions.load(id).to_h).to eq(before.to_h)
        expect(chat.calls.length).to eq(1)
        expect(chat.calls.first.key?("response_format")).to eq(delivery == :native)
        expect(before.metadata.fetch("output_contract")).to include("version" => 2, "schema_delivery" => delivery.to_s)
      end
    end

    it "resumes approval with its original schema and #{delivery} delivery through a fresh pool" do
      executions = 0
      tool = Class.new(Phronomy::Tool::Base) do
        tool_name "structured_lookup"
        description "Read an approved value"
        requires_approval true
        define_method(:execute) { executions += 1; "known" }
      end
      structured_agent.tools tool => nil
      chat = ExampleChatStub.new do |_request, index|
        index.zero? ? ExampleChatStub.tool("structured_lookup") : '{"answer":"known"}'
      end
      approvals = Queue.new
      listener = ->(event) { approvals << event.payload.fetch(:request) if event.type == :approval_required }
      agent = structured_agent.create(persistence: initial_storage.fetch(0).agent, on_event: listener)
      agent.invoke_async("question", output_schema: output_schema, schema_delivery: delivery)
      request = approvals.pop(timeout: 5)
      expect(request).not_to be_nil
      expect(executions).to eq(0)
      output_schema[:properties][:answer][:type] = "number"
      restored = reopen_structured_storage
      loaded = structured_agent.load(agent.agent_id, persistence: restored.agent, on_event: listener)
      approval = approvals.pop(timeout: 5)
      expect(approval.id).to eq(request.id)
      result = loaded.approve(request.execution_id, approval_request_id: approval.id, approved: true)
      expect(result[:output]).to eq("answer" => "known")
      expect(executions).to eq(1)
      expect(chat.calls.length).to eq(2)
      expect(loaded.transcript_messages.map(&:to_h)).to eq(result[:messages].map(&:to_h))
      if delivery == :native
        expect(chat.calls.last.dig("response_format", "json_schema", "schema", "properties", "answer", "type")).to eq("string")
      else
        expect(chat.calls).to all(satisfy { |request| !request.key?("response_format") })
      end
    end
  end
end
