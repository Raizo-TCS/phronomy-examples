# frozen_string_literal: true

require "spec_helper"

RSpec.describe "GeneratorVerifier application composition" do
  let(:example_root) { File.expand_path("../19_trust_pipeline", __dir__) }

  it "runs all scenarios and releases each pair of Agents" do
    chat = ExampleChatStub.new do |_body, index|
      if index.even?
        JSON.generate(answer: "A supported answer long enough for application validation.", confidence: 0.9,
          citations: [{source: "policy.md", excerpt: "policy evidence"}])
      else
        JSON.generate(approved: true, score: 0.9, feedback: "")
      end
    end
    released = []
    require File.join(example_root, "agents")
    [PolicyDraftAgent, PolicyReviewAgent].each do |agent_class|
      allow(agent_class).to receive(:new).and_wrap_original do |constructor, **options|
        agent = constructor.call(**options)
        allow(agent).to receive(:unload!).and_wrap_original do |method|
          value = method.call
          released << value
          value
        end
        agent
      end
    end
    expect { load File.join(example_root, "run.rb") }
      .to output(/Reason: accepted.*Accepted: true.*policy.md/m).to_stdout
    expect(chat.calls.length).to eq(6)
    expect(released).to eq([true] * 6)
  end

  it "does not classify a high-score review denial as acceptance" do
    ExampleChatStub.new do |_body, index|
      index.even? ?
        JSON.generate(answer: "Draft answer.", confidence: 0.95, citations: []) :
        JSON.generate(approved: false, score: 0.95, feedback: "Unsupported claim")
    end
    require File.join(example_root, "agents")
    result = Phronomy::GeneratorVerifier.open(
      draft_agent: PolicyDraftAgent, review_agent: PolicyReviewAgent,
      draft_prompt_builder: ->(input, _feedback) { input },
      review_prompt_builder: ->(_input, draft, _citations) { draft },
      max_iterations: 1
    ) { |pipeline| pipeline.invoke("question") }
    expect(result).not_to be_accepted
    expect(result.termination_reason).to eq("iteration_limit")
    expect(Phronomy::GeneratorVerifier::Result.from_h(JSON.parse(JSON.generate(result.to_h)))).to eq(result)
  end
end

RSpec.describe "GeneratorVerifier approval CLI" do
  [true, false].each do |approved|
    it "lets the application #{approved ? "approve" : "deny"} the selected Tool" do
      chat = ExampleChatStub.new do |_body, index|
        case index
        when 0
          ExampleChatStub.tool("approved_policy_lookup", query: "refund policy")
        when 1
          JSON.generate(answer: "Refunds are available within the policy window.", confidence: 0.9, citations: [])
        else
          JSON.generate(approved: true, score: 0.9, feedback: "")
        end
      end
      previous_stdin = $stdin
      $stdin = StringIO.new(approved ? "yes\n" : "no\n")
      expect { load File.expand_path("../19_trust_pipeline/approval_demo.rb", __dir__) }
        .to output(/"termination_reason": "#{approved ? "accepted" : "tool_rejected"}"/).to_stdout
      expect(chat.calls.length).to eq(approved ? 3 : 1)
      expect(chat.calls.map { |body| body.fetch("model") }.uniq).to eq([LLMConfig::MODEL])
    ensure
      $stdin = previous_stdin
    end
  end
end

RSpec.describe "Structured output application recipes" do
  it "rejects schema-valid but unfaithful invoice extraction without repairing or replaying it" do
    chat = ExampleChatStub.new { '{"invoice_id":"INV-2026-01","total":1250}' }
    expect {
      expect { load File.expand_path("../19_trust_pipeline/structured_agent_demo.rb", __dir__) }
        .to raise_error(SystemExit) { |error| expect(error.status).to eq(1) }
    }.to output(/Invoice fidelity failed.*INV-2026-001.*INV-2026-01/).to_stderr
    expect(chat.calls.length).to eq(1)
    expect(chat.calls.first.dig("response_format", "json_schema", "schema", "properties", "invoice_id")).to eq({"type" => "string"})
  end

  it "prints validated Agent values from a directly returned Task" do
    chat = ExampleChatStub.new { '{"invoice_id":"INV-2026-001","total":1250}' }
    expect { load File.expand_path("../19_trust_pipeline/structured_agent_demo.rb", __dir__) }
      .to output(/Invoice: INV-2026-001.*Total: 1250/m).to_stdout
    expect(chat.calls.first.dig("response_format", "type")).to eq("json_schema")
  end

  it "awaits the pipeline's directly returned Task before cleanup" do
    ExampleChatStub.new do |_body, index|
      index.even? ? '{"answer":"supported","confidence":0.9,"citations":[]}' : '{"approved":true,"score":0.9,"feedback":""}'
    end
    expect { load File.expand_path("../19_trust_pipeline/lifetime_demo.rb", __dir__) }.to output("accepted\n").to_stdout
  end

  it "shows malformed output as acquisition failure without retrying that attempt" do
    chat = ExampleChatStub.new { "malformed" }
    expect { load File.expand_path("../19_trust_pipeline/run.rb", __dir__) }
      .to output(/Reason: output_failed.*agent.output_invalid.*invalid_json/m).to_stdout
    expect(chat.calls.length).to eq(3) # One request per independent scenario, no repair/review.
  end
end
