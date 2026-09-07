# frozen_string_literal: true

# Protocol-level stubbing keeps the real Agent, Tool, Team and Persistence paths.
# The responder chooses a tool from the actual advertised schema, so tests do
# not depend on Phronomy's private Handoff transport-name encoding.
class ExampleChatStub
  attr_reader :calls

  def initialize(&responder)
    @calls = []
    WebMock.stub_request(:post, "https://example.test/v1/chat/completions")
      .to_return do |request|
        body = JSON.parse(request.body)
        @calls << body
        response = responder.call(body, @calls.length - 1)
        message = response.is_a?(Hash) ? response : {role: "assistant", content: response.to_s}
        {status: 200, headers: {"Content-Type" => "application/json"},
         body: JSON.generate(id: "chatcmpl-example-#{@calls.length}", object: "chat.completion",
           created: 0, model: "gpt-4o-mini", choices: [
             {index: 0, message: message, finish_reason: message[:tool_calls] ? "tool_calls" : "stop"}
           ], usage: {prompt_tokens: 10, completion_tokens: 5, total_tokens: 15})}
      end
  end

  def self.tool(name, arguments = {})
    {role: "assistant", content: nil, tool_calls: [
      {id: "call-example-#{SecureRandom.hex(6)}", type: "function",
       function: {name: name, arguments: JSON.generate(arguments)}}
    ]}
  end
end
