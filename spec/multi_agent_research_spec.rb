# frozen_string_literal: true

require "spec_helper"
require_relative "../05_multi_agent/agents"

RSpec.describe "Example 05 research-to-writer handoff" do
  let(:notes) { "- First verified fixture finding.\n- Second finding.\n- Third finding.\n- Fourth finding.\n- Fifth finding." }
  let(:article) { "A technical article based on the supplied research notes. " * 8 }
  let(:entrypoint) { File.expand_path("../05_multi_agent/run.rb", __dir__) }

  around do |example|
    previous = Phronomy.configuration.before_llm_input
    previous_chars = $accumulated_tool_chars
    example.run
  ensure
    Phronomy.configuration.before_llm_input = previous
    $accumulated_tool_chars = previous_chars
  end

  def fixture(notes:, article:, mode: :valid)
    calls = []
    WebMock.stub_request(:post, "https://example.test/v1/chat/completions").to_return do |request|
      body = JSON.parse(request.body)
      calls << body
      index = calls.length - 1
      answer = case index
      when 0
        mode == :skip ? article : ExampleChatStub.tool("research", topic: "Ruby 3.4")
      when 1
        notes
      when 2
        if mode == :empty
          article
        else
          supplied_notes = mode == :substitute ? "Invented notes never returned by the researcher." : notes
          ExampleChatStub.tool("write", instructions: "Write a short article.", research_notes: supplied_notes)
        end
      when 3
        mode == :empty_writer ? "" : article
      else
        case mode
        when :replace_article then "An unrelated article. " * 30
        when :format_article then article.sub("\n", "  \n")
        else "The article is ready."
        end
      end
      message = answer.is_a?(Hash) ? answer : {role: "assistant", content: answer}
      reason = message[:tool_calls] ? "tool_calls" : "stop"
      if (index == 1 && mode == :empty) || (index == 3 && mode == :empty_writer)
        message[:reasoning_content] = "Planning research without emitting a final answer."
        reason = "length"
      end
      {status: 200, headers: {"Content-Type" => "application/json"}, body: JSON.generate(
        id: "fixture-#{index}", object: "chat.completion", created: 0, model: "gpt-4o-mini",
        choices: [{index: 0, message: message, finish_reason: reason}],
        usage: {prompt_tokens: 10, completion_tokens: reason == "length" ? 2048 : 10})}
    end
    calls
  end

  it "passes actual research verbatim into the writer prompt and accepts the resulting article" do
    calls = fixture(notes: notes, article: article)
    expect { load entrypoint }.to output(/OK: nonblank research passed to the writer/).to_stdout
    expect(calls.length).to eq(5)
    expect(calls[1].fetch("max_completion_tokens")).to eq(2048)
    expect(calls[3].fetch("max_completion_tokens")).to eq(2048)
    prompt = calls[3].fetch("messages").last.fetch("content")
    expect(prompt).to eq("Writing brief:\nWrite a short article.\n\nResearch notes:\n#{notes}")
  end

  it "rejects reasoning-only research instead of accepting an unrelated long final article" do
    calls = fixture(notes: "", article: article, mode: :empty)
    expect { load entrypoint }.to raise_error(Phronomy::ToolError, /Researcher returned no final-answer text/)
    expect(calls.length).to eq(2)
    expect(calls.none? { |request| request["messages"].any? { |m| m["content"].to_s.start_with?("Writing brief:") } }).to be(true)
  end

  it "rejects a reasoning-only writer result without asking the orchestrator to fabricate an article" do
    calls = fixture(notes: notes, article: article, mode: :empty_writer)
    expect { load entrypoint }.to raise_error(Phronomy::ToolError, /Writer returned no final-answer text/)
    expect(calls.length).to eq(4)
  end

  it "rejects a long article when the orchestrator skips both Tools without rerunning the task" do
    calls = fixture(notes: notes, article: article, mode: :skip)
    expect { load entrypoint }.to raise_error(Example05Validation::InvalidOutput, /No completed research-to-write handoff/)
    expect(calls.length).to eq(1)
  end

  it "rejects substituted notes even when research and writing both return nonempty results" do
    calls = fixture(notes: notes, article: article, mode: :substitute)
    expect { load entrypoint }.to raise_error(Example05Validation::InvalidOutput, /complete earlier research result/)
    expect(calls.length).to eq(5)
  end

  it "publishes the writer article rather than replacement text from the orchestrator" do
    fixture(notes: notes, article: article, mode: :replace_article)
    expect { load entrypoint }.to output(satisfy { |text|
      text.include?("--- Final Article ---\n#{article}\n") && !text.include?("An unrelated article.")
    }).to_stdout
  end

  it "preserves the writer's exact formatting when the orchestrator adds Markdown line-break spaces" do
    original = "#{article}\nFinal paragraph."
    fixture(notes: notes, article: original, mode: :format_article)
    expect { load entrypoint }.to output(satisfy { |text|
      text.include?("--- Final Article ---\n#{original}\n") && !text.include?(original.sub("\n", "  \n"))
    }).to_stdout
  end

  it "rejects blank notes before invoking the writer" do
    expect { WriteTool.new.call({instructions: "Write an article.", research_notes: " \n"}) }
      .to raise_error(Phronomy::ToolError, /Writing requires nonblank research notes/)
    expect(WebMock).not_to have_requested(:post, "https://example.test/v1/chat/completions")
  end

  it "does not correlate a write request with a later research result" do
    research = Phronomy::Tool::CallRequest.new(id: "r", name: "research", arguments: {topic: "Ruby"})
    write = Phronomy::Tool::CallRequest.new(id: "w", name: "write", arguments: {instructions: "Write", research_notes: notes})
    messages = [
      Phronomy::LLMAdapter::Message.new(role: :assistant, tool_calls: [research, write]),
      Phronomy::LLMAdapter::Message.new(role: :tool, tool_call_id: "r", content: notes),
      Phronomy::LLMAdapter::Message.new(role: :tool, tool_call_id: "w", content: article)
    ]
    expect { Example05Validation.article!(output: article, messages: messages) }
      .to raise_error(Example05Validation::InvalidOutput, /complete earlier research result/)
  end

  it "retains the minimum final article length requirement" do
    calls = fixture(notes: notes, article: "Too short")
    expect { load entrypoint }.to raise_error(Example05Validation::InvalidOutput, /at least 300/)
    expect(calls.length).to eq(5)
  end

  it "selects the last correlated writer result without rewriting the orchestrator result or transcript" do
    research = Phronomy::Tool::CallRequest.new(id: "r", name: "research", arguments: {topic: "Ruby"})
    writes = %w[w1 w2].map { |id|
      Phronomy::Tool::CallRequest.new(id: id, name: "write", arguments: {instructions: "Write", research_notes: notes})
    }
    messages = [
      Phronomy::LLMAdapter::Message.new(role: :assistant, tool_calls: [research]),
      Phronomy::LLMAdapter::Message.new(role: :tool, tool_call_id: "r", content: notes)
    ]
    writes.each_with_index do |write, index|
      messages << Phronomy::LLMAdapter::Message.new(role: :assistant, tool_calls: [write])
      messages << Phronomy::LLMAdapter::Message.new(role: :tool, tool_call_id: write.id, content: "Draft #{index}: #{article}")
    end
    result = {output: "The article is ready.", messages: messages}
    original = JSON.generate(result)
    expect(Example05Validation.article!(result)).to eq("Draft 1: #{article}")
    expect(JSON.generate(result)).to eq(original)
  end

  it "does not publish an uncorrelated Tool message even if the orchestrator returns a long article" do
    messages = [Phronomy::LLMAdapter::Message.new(role: :tool, tool_call_id: "unknown", content: article)]
    expect { Example05Validation.article!(output: article, messages: messages) }
      .to raise_error(Example05Validation::InvalidOutput, /No completed research-to-write handoff/)
  end
end
