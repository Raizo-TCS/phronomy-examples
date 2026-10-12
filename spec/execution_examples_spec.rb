# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Example execution boundaries" do
  def run_example(name, *arguments)
    saved_arguments = ARGV.dup
    ARGV.replace(arguments)
    load File.expand_path("../#{name}/run.rb", __dir__)
  ensure
    ARGV.replace(saved_arguments)
    Object.send(:remove_const, :SEND_NODE) if name == "04_interrupt_resume" && Object.const_defined?(:SEND_NODE, false)
  end

  it "runs the basic pipeline with three independent Agent Tasks" do
    stub = ExampleChatStub.new { 'puts "Hello World from the generated program"' }
    expect { run_example("01_basic_chain") }.to output(/Language: Ruby.*Language: Python.*Language: JavaScript/m).to_stdout
    expect(stub.calls.length).to eq(3)
  end

  it "retains tracing while task_state applies the Agent output" do
    stub = ExampleChatStub.new { 'fmt.Println("Hello World from Go")' }
    expect { run_example("07_tracing") }.to output(/LLM Response.*Hello World from Go/m).to_stdout
    expect(stub.calls.length).to eq(1)
  ensure
    Phronomy.reset_configuration!
  end

  it "keeps Agent lifecycle observation separate from Workflow task completion" do
    stub = ExampleChatStub.new { "\u304a\u306f\u3088\u3046\u3054\u3056\u3044\u307e\u3059\u3002" }
    expect { run_example("26_agent_event_loop") }
      .to output(/Workflow answer:.*\u304a\u306f\u3088\u3046\u3054\u3056\u3044\u307e\u3059.*Caught:.*TimeoutError/m).to_stdout
    expect(stub.calls.length).to eq(2)
  end

  it "completes a Workflow improvement loop through task_state results" do
    responses = ["2", "Ruby enables clear, maintainable applications with expressive code and useful libraries.", "8"]
    stub = ExampleChatStub.new { |_request, index| responses.fetch(index) }
    expect { run_example("03_state_graph") }
      .to output(/Iteration 0.*Score: 2.*Iteration 1.*Score: 8.*Final text:/m).to_stdout
    expect(stub.calls.length).to eq(3)
  end

  [["no", "yes"], ["yes", "no"]].each do |workflow_answer, tool_answer|
    it "keeps Workflow approval #{workflow_answer} independent of tool approval #{tool_answer}" do
      stub = ExampleChatStub.new do |_request, index|
        case index
        when 0
          "Subject: Project completion report\n\nThe project is complete. Thank you for your support throughout the work. Please review the attached summary and share any questions."
        when 1
          ExampleChatStub.tool("publish_release", version: "2.4.0", environment: "production")
        else
          "The approved release was published to production successfully."
        end
      end
      workflow_output = workflow_answer == "yes" ? "Workflow approved=true" : "Draft was not sent."
      approved = tool_answer == "yes"
      expected = /#{Regexp.escape(workflow_output)}.*Original TaskResult done:  false.*Tool approved:       #{approved}.*Execution rejected:  #{!approved}.*Original TaskResult done:  true/m
      expect { run_example("04_interrupt_resume", workflow_answer, tool_answer) }.to output(expected).to_stdout
      expect(stub.calls.length).to eq(approved ? 3 : 2)
    end
  end

  it "retrieves actual local documents before answering the RAG example" do
    stub = ExampleChatStub.new do |request, index|
      if index.zero?
        ExampleChatStub.tool("search_knowledge", query: "standard shipping delivery")
      else
        evidence = request.fetch("messages").find { |message| message["role"] == "tool" }.fetch("content")
        expect(evidence).to include("3-5 business days")
        "Standard shipping normally takes 3-5 business days."
      end
    end
    expect { run_example("24_vector_store_dimension") }
      .to output(/Mismatched add rejected:.*Retrieved through 1 VectorSearch call/m).to_stdout
    expect(stub.calls.length).to eq(2)
  end

  it "completes external work through task_state and async handles" do
    expect { run_example("25_event_loop") }
      .to output(/SUMMARY:.*Completed 3 async Workflow invocations/m).to_stdout
    expect(WebMock).not_to have_requested(:any, /chat\/completions/)
  end

  it "blocks input before the Provider and applies tool-result and output filters" do
    stub = ExampleChatStub.new do |_request, index|
      if index.even?
        ExampleChatStub.tool("customer_lookup", customer_id: index.zero? ? "42" : "99")
      else
        "Customer email: alice@example.test; tier: gold."
      end
    end
    expect { run_example("28_filter") }
      .to output(/Blocked:.*Filtered tool result:.*\[EMAIL REDACTED\].*Output:.*\[EMAIL REDACTED\]/m).to_stdout
    expect(stub.calls.length).to eq(4)
    user_text = stub.calls.flat_map { |request| request.fetch("messages") }
      .select { |message| message["role"] == "user" }.map { |message| message["content"] }.join
    expect(user_text).not_to include("TOP-SECRET")
  end
end
