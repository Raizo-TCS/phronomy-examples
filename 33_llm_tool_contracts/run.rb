# frozen_string_literal: true

require "phronomy"

module ContractExample
  class DoubleValue < Phronomy::Tool::Base
    tool_name "double_value"
    description "Double a validated integer"
    on_schema_error :raise
    parameters({"type" => "object", "properties" => {"n" => {"type" => "integer", "minimum" => 1}},
                "required" => ["n"], "additionalProperties" => false})
    def execute(n:) = (n * 2).to_s
  end

  class LocalBackend < Phronomy::LLMAdapter::Base
    protected

    def perform_complete(request, cancellation_token:)
      result = request.messages.reverse.find { |message| message.role == :tool }
      if result
        Phronomy::LLMAdapter::Response.new(content: "Result: #{result.content}")
      else
        Phronomy::LLMAdapter::Response.new(tool_calls: [
          Phronomy::Tool::CallRequest.new(id: "double-1", name: "double_value", arguments: {"n" => 3})
        ])
      end
    end

    def perform_stream(request, cancellation_token:)
      result = perform_complete(request, cancellation_token: cancellation_token)
      yield Phronomy::LLMAdapter::StreamChunk.new(content: result.content) if result.content
      result
    end
  end

  class Agent < Phronomy::Agent::Base
    agent_definition id: "local-contract-example", version: 1
    model "local-example"
    tools DoubleValue => nil
  end

  def self.run
    Phronomy.configure { |config| config.llm_adapter = LocalBackend.new }
    Agent.new.invoke("Double three")[:output]
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    puts ContractExample.run
  ensure
    Phronomy.reset_runtime!
  end
end
