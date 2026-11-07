# frozen_string_literal: true

require "phronomy"
require_relative "../22_shared_state/adaptive_shared_state"

RSpec.describe AdaptiveSharedState do
  let(:store) { Phronomy::MultiAgent::SharedState::KnowledgeStore.new }
  let(:budget) { SharedReadBudget.new }
  let(:reader) { AdaptiveFindingReader.new(store, budget: budget) }
  let(:policy) { AdaptiveReviewContextPolicy.new(store: store) }

  def input(window, instruction_tokens: 100, conversation: [])
    types = Phronomy::Context::ContextPolicyInput
    instruction = types::InstructionItem.new(id: "instructions", kind: :instruction,
      role: :system, content: "I" * (instruction_tokens * 4), estimated_tokens: instruction_tokens,
      required: true)
    current = types::ConversationItem.new(id: "request", kind: :external_message,
      role: :user, content: "U" * 400, estimated_tokens: 100,
      required: true, sequence: 0)
    types.new(agent_id: "adaptive-test", execution_id: "execution-test", call_sequence: 1,
      call_mode: :complete, instruction: [instruction], tools: [], knowledge: [],
      conversation: [[current], *conversation], previous_manifest: nil,
      token_budget: window && Phronomy::LlmContextWindow::TokenBudget.new(max_input_tokens: window))
  end

  def add(content)
    store.write(agent: :QualityReviewer, cycle: 1, content: content)
  end

  def cost(value)
    Phronomy::LlmContextWindow::TokenEstimator.estimate(value.is_a?(String) ? value : JSON.generate(value))
  end

  def exchange(requests = [{}], assistant_text: "", required: true)
    types = Phronomy::Context::ContextPolicyInput
    calls = requests.each_with_index.map { |args, index| {id: "call-#{index}", name: "read_store", arguments: args} }
    assistant_content = {role: "assistant", content: assistant_text, tool_calls: calls}
    assistant = types::ConversationItem.new(id: "tool-request", kind: :assistant_message,
      role: :assistant, content: JSON.parse(assistant_content.to_json), estimated_tokens: cost(assistant_content),
      required: required, sequence: 1, tool_call_ids: calls.map { |call| call[:id] })
    responses = calls.map.with_index do |call, index|
      receipt = AdaptiveFindingReader.request(store, **call[:arguments])
      content = {role: "tool", tool_call_id: call[:id], content: receipt.to_json}
      types::ConversationItem.new(id: "tool-response-#{index}", kind: :tool_message,
        role: :tool, content: JSON.parse(content.to_json), estimated_tokens: cost(content), required: required,
        sequence: index + 2, tool_call_id: call[:id])
    end
    [assistant, *responses]
  end

  def lookup_pages(plan)
    plan.knowledge.filter_map do |item|
      value = JSON.parse(item.content)
      value if value["type"] == "shared_findings_page"
    end
  end

  def plan_cost(plan)
    items = plan.instruction + plan.knowledge + plan.conversation.flatten
    items.sum { |item| cost(item.content) } + cost(plan.tools.map(&:definition))
  end

  it "adapts retrieved volume to the window without changing the full store" do
    41.times { |i| add("Finding #{i}: " + "Original source detail. " * 25) }
    original = store.read_all
    pages = [8192, 16_384, 32_768].map do |window|
      plan = policy.call(input(window, conversation: [exchange]))
      expect(plan_cost(plan)).to be <= plan.metadata.fetch("adaptive_input_limit")
      lookup_pages(plan).first.fetch("page")
    end
    counts = pages.map { |page| page.fetch("findings").length }
    expect(counts[0]).to be < counts[1]
    expect(counts[1]).to be < counts[2]
    expect(counts[2]).to eq(41)
    expect(pages.last.fetch("next_before_id")).to be_nil
    expect(store.read_all).to eq(original)
  end

  it "reduces aggregate retrieval room when persistent required input grows" do
    initial = policy.call(input(8192, conversation: [exchange]))
    larger = policy.call(input(8192, instruction_tokens: 1000, conversation: [exchange]))
    expect(larger.metadata.fetch("shared_result_budget")).to be < initial.metadata.fetch("shared_result_budget")
  end

  it "delegates optional history selection and preserves required inputs" do
    history = 15.times.map do |i|
      [Phronomy::Context::ContextPolicyInput::ConversationItem.new(id: "history-#{i}",
        kind: :conversation, role: :assistant, content: "H" * 1800,
        estimated_tokens: 450, required: false, sequence: i + 1)]
    end
    source = input(8192, conversation: history)
    plan = policy.call(source)
    expect(plan.conversation.length).to be < source.conversation.length
    expect(plan.conversation.flatten).to include(source.conversation.first.first)
    expect(plan.metadata.fetch("adaptive_input_limit")).to be < 8192
    expect { Phronomy::Context::ContextPlanValidator.new.validate!(input: source, plan: plan) }.not_to raise_error
    expect { policy.call(input(8192, instruction_tokens: 6000)) }.to raise_error(Phronomy::Context::BudgetExceededError)
  end

  it "preserves receipts and budgets the complete exchange plus multiple escaped lookup results" do
    add("\\" * 20_000)
    group = exchange([{}, {}], assistant_text: "I am inspecting the stored findings. " * 6)
    source = input(8192, conversation: [group])
    plan = policy.call(source)
    pages = lookup_pages(plan)
    expect(pages.map { |page| page.fetch("tool_call_id") }).to eq(%w[call-0 call-1])
    expect(pages.all? { |page| page.fetch("page").fetch("findings").first.fetch("truncated") }).to be(true)
    expect(plan.conversation).to include(group)
    expect(plan.knowledge.all?(&:required?)).to be(true)
    expect(plan.metadata.fetch("shared_result_tokens")).to be <= plan.metadata.fetch("shared_result_budget")
    expect(plan_cost(plan)).to be <= plan.metadata.fetch("adaptive_input_limit")
    expect { Phronomy::Context::ContextPlanValidator.new.validate!(input: source, plan: plan) }.not_to raise_error
  end

  it "resolves only current required requests, without replaying optional historical receipts" do
    add("An observation")
    source = input(8192, conversation: [exchange(required: false)])
    expect(lookup_pages(policy.call(source))).to eq([])
  end

  it "retains the Tool-time snapshot when a later write adds another finding" do
    add("Existing finding")
    group = exchange
    add("Later finding")
    page = lookup_pages(policy.call(input(8192, conversation: [group]))).first
    expect(page.fetch("snapshot_size")).to eq(1)
    expect(page.fetch("page").fetch("findings").map { |entry| entry.fetch("content") }).to eq(["Existing finding"])
    expect(store.size).to eq(2)
  end

  it "recovers every record across budget changes and appends using stable cursors" do
    30.times { |i| add("Finding #{i}: " + "Detailed observation. " * 20) }
    budget.update(800)
    first = reader.read
    seen = first[:findings].map { |entry| entry[:id] }
    add("Appended after the first page")
    cursor = first[:next_before_id]
    while cursor
      budget.update(500 + (seen.length % 3) * 100)
      page = reader.read(before_id: cursor)
      expect(cost(page)).to be <= budget.tokens
      seen.concat(page[:findings].map { |entry| entry[:id] })
      cursor = page[:next_before_id]
    end
    expect(seen).to eq((1..30).to_a.reverse)
    expect(store.size).to eq(31)
  end

  it "keeps irreducible required Tool results intact and rejects insufficient room" do
    types = Phronomy::Context::ContextPolicyInput
    assistant_content = {role: "assistant", tool_calls: [{id: "call", name: "read_file", arguments: {}}]}
    assistant = types::ConversationItem.new(id: "tool-request", kind: :assistant_message,
      role: :assistant, content: JSON.parse(assistant_content.to_json),
      estimated_tokens: cost(assistant_content), required: true, sequence: 1, tool_call_ids: ["call"])
    response_content = {role: "tool", tool_call_id: "call", content: "Full finding. " * 2000}
    response = types::ConversationItem.new(id: "tool-response", kind: :tool_message,
      role: :tool, content: JSON.parse(response_content.to_json),
      estimated_tokens: cost(response_content), required: true, sequence: 2, tool_call_id: "call")
    group = [assistant, response]
    expect { policy.call(input(8192, conversation: [group])) }.to raise_error(Phronomy::Context::BudgetExceededError)
    larger = input(16_384, conversation: [group])
    plan = policy.call(larger)
    expect(plan.conversation).to include(group)
    expect { Phronomy::Context::ContextPlanValidator.new.validate!(input: larger, plan: plan) }.not_to raise_error
  end

  it "retrieves oversized text in lossless chunks including the complete knowledge envelope cost" do
    text = "Original text with quotes \" and slashes \\ and lines\n" * 150
    add(text)
    budget.update(180)
    wrap = ->(page) { {type: "shared_findings_page", tool_call_id: "call-123", page: page} }
    result = reader.read(wrap: wrap)
    expect(cost(result)).to be <= budget.tokens
    entry = result[:page][:findings].first
    expect(entry[:truncated]).to be(true)
    recovered = entry[:content]
    offset = entry[:next_content_offset]
    while offset
      result = reader.read(finding_id: 1, content_offset: offset, wrap: wrap)
      expect(cost(result)).to be <= budget.tokens
      entry = result[:page][:finding]
      expect(entry[:next_content_offset]).to be > offset if entry[:truncated]
      recovered += entry[:content]
      offset = entry[:next_content_offset]
    end
    expect(recovered).to eq(text)
    expect(store.read_all.first[:content]).to eq(text)
  end

  it "searches full text and validates request cursors before issuing a receipt" do
    add("prefix " * 200 + " CERTIFICATE_MATCH")
    budget.update(250)
    expect(reader.read(query: "certificate_match")[:remaining_matches]).to eq(1)
    expect { AdaptiveFindingReader.request(store, finding_id: 2) }.to raise_error(ArgumentError, "Unknown finding ID")
    expect { AdaptiveFindingReader.request(store, before_id: 0) }.to raise_error(ArgumentError)
    expect { AdaptiveFindingReader.request(store, finding_id: 1, content_offset: -1) }.to raise_error(ArgumentError)
    expect { reader.read(snapshot_size: 2) }.to raise_error(ArgumentError, "Unknown shared-store snapshot")
    budget.update(1)
    expect { reader.read }.to raise_error(Phronomy::Context::BudgetExceededError)
  end

  it "requires known metadata instead of guessing a model limit" do
    expect { policy.call(input(nil)) }.to raise_error(Phronomy::ConfigurationError, /metadata/)
    expect { reader.read }.to raise_error(Phronomy::ConfigurationError, /known context budget/)
  end

  it "binds independent generated-member policies and keeps the per-invocation call guard" do
    member = Class.new(Phronomy::Agent::Base) do
      agent_definition id: "adaptive-test-member", version: 1
    end
    first = described_class.new.send(:build_instrumented_researcher, member, store, 1)
    second = described_class.new.send(:build_instrumented_researcher, member, store, 2)
    first_plan = first.context_policy.call(input(8192, conversation: [exchange]))
    second_plan = second.context_policy.call(input(32_768, conversation: [exchange]))
    expect(first.context_policy).not_to equal(second.context_policy)
    expect(first_plan.metadata.fetch("shared_result_budget")).to be < second_plan.metadata.fetch("shared_result_budget")
    expect([first.max_iterations, second.max_iterations]).to eq([30, 30])
    first_tool = first.tools.find { |tool| tool.tool_name == "read_store" }
    receipt = JSON.parse(first_tool.new.execute)
    expect(receipt.slice("type", "version", "snapshot_size")).to eq(
      "type" => "shared_findings_request", "version" => 1, "snapshot_size" => 0
    )
  end
end
