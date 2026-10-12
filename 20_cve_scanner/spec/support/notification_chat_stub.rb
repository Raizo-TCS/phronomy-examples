# frozen_string_literal: true

# Stub only the HTTP protocol. Real Agents, Tools, event listeners and the
# Workflow still execute, including streamed token/tool-call events.
class NotificationChatStub
  attr_reader :calls

  def initialize(&responder)
    @calls = []
    WebMock.stub_request(:post, "https://example.test/v1/chat/completions").to_return do |request|
      body = JSON.parse(request.body)
      @calls << body
      answer = responder.call(body, @calls.length - 1)
      message = answer.is_a?(Hash) ? answer : {role: "assistant", content: answer.to_s}
      if body["stream"]
        deltas = [{role: "assistant"}]
        if message[:tool_calls]
          deltas << {tool_calls: message[:tool_calls].each_with_index.map { |call, index| call.merge(index: index) }}
        else
          deltas.concat(message.fetch(:content, "").scan(/.{1,12}/m).map { |chunk| {content: chunk} })
        end
        finish = message[:tool_calls] ? "tool_calls" : "stop"
        chunks = deltas.map { |delta| chunk(delta, nil) } + [chunk({}, finish)]
        {status: 200, headers: {"Content-Type" => "text/event-stream"},
         body: chunks.map { |entry| "data: #{JSON.generate(entry)}\n\n" }.join + "data: [DONE]\n\n"}
      else
        {status: 200, headers: {"Content-Type" => "application/json"},
         body: JSON.generate(id: "notification-chat", object: "chat.completion", created: 0,
           model: "gpt-4o-mini", choices: [{index: 0, message: message,
             finish_reason: message[:tool_calls] ? "tool_calls" : "stop"}],
           usage: {prompt_tokens: 10, completion_tokens: 5, total_tokens: 15})}
      end
    end
  end

  private

  def chunk(delta, finish)
    {id: "notification-chat", object: "chat.completion.chunk", created: 0, model: "gpt-4o-mini",
     choices: [{index: 0, delta: delta, finish_reason: finish}]}
  end
end
