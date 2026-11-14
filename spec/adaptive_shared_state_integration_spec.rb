# frozen_string_literal: true

require_relative "spec_helper"
require_relative "../22_shared_state/team"

RSpec.describe "Adaptive shared-state execution" do
  def reviewer(name, tool_classes: [])
    Class.new(Phronomy::Agent::Base) do
      agent_definition id: "adaptive-integration-#{name}", version: 1
      model "gpt-4o-mini"
      provider :openai
      instructions "Read shared findings and return a concise review."
      tools(tool_classes.to_h { |tool_class| [tool_class, nil] }) unless tool_classes.empty?
      define_singleton_method(:name) { name }
    end
  end

  def with_seeded_agent(content, tool_classes: [])
    store = ReviewFindingStore.new
    store.write(agent: :EarlierReviewer, cycle: 1, content: content)
    sharing = ReviewSharing.new(store: store)
    prepared = sharing.prepare_member(reviewer("Reader", tool_classes: tool_classes))
    sharing.open(input: "Read shared findings", config: {}) do |binding|
      definitions = prepared.tools.to_h { |tool| [tool, prepared.tool_aliases[tool]] }
      generated = prepared.with_tools(definitions.merge(binding.tool_definitions(member: prepared, cycle: 2)),
        id: "adaptive-integration-reader-bound", version: 1)
      agent = generated.new
      begin
        yield agent, store
      ensure
        agent.unload!
      end
    end
    expect(store.closed).to be(true)
  end

  def review_team(sharing, members, cycles: 1, &aggregate)
    Class.new(Phronomy::MultiAgent::SharedState).tap do |team|
      team.sharing(sharing, id: "adaptive-integration-sharing", version: 3)
      members.each { |member| team.member(sharing.prepare_member(member)) }
      team.max_cycles(cycles)
      team.coordination("Read shared findings, write one new finding, then finish.")
      team.aggregate(&aggregate || ->(store) { store.read_all })
    end
  end

  def latest_tool_results(request)
    messages = request.fetch("messages")
    latest_assistant = messages.rindex { |message| message["tool_calls"]&.any? }
    return [] unless latest_assistant

    messages[(latest_assistant + 1)..].select { |message| message["role"] == "tool" }
  end

  def shared_pages(request)
    request.fetch("messages").filter_map do |message|
      next unless message["role"] == "user"

      begin
        value = JSON.parse(message.fetch("content"))
        value if value.is_a?(Hash) && value["type"] == "shared_findings_page"
      rescue JSON::ParserError
        nil
      end
    end
  end

  def expect_paired_shared_pages(request, expected_snapshots:)
    receipts = latest_tool_results(request).select do |message|
      JSON.parse(message.fetch("content"))["type"] == "shared_findings_request"
    rescue JSON::ParserError
      false
    end
    expect(receipts.length).to eq(expected_snapshots.length)
    receipts.each_with_index do |message, index|
      receipt = JSON.parse(message.fetch("content"))
      expect(receipt.fetch("snapshot_size")).to eq(expected_snapshots.fetch(index))
      expect(receipt.keys.sort).to eq(%w[request snapshot_size type version])
      expect(receipt.fetch("version")).to eq(1)
    end
    expect(shared_pages(request).map { |page| page.fetch("tool_call_id") })
      .to match_array(receipts.map { |message| message.fetch("tool_call_id") })
  end

  it "fits two shared reads in one actual Tool exchange before the next LLM call" do
    original = "A" * 20_000
    with_seeded_agent(original) do |agent, store|
      observed_pages = []
      transport = ExampleChatStub.new do |request, index|
        if index.zero?
          first = ExampleChatStub.tool("read_store")
          second = ExampleChatStub.tool("read_store")
          first.merge(tool_calls: first.fetch(:tool_calls) + second.fetch(:tool_calls))
        else
          expect_paired_shared_pages(request, expected_snapshots: [1, 1])
          observed_pages = shared_pages(request).map { |envelope| envelope.fetch("page") }
          "Both shared reads were received."
        end
      end

      result = agent.invoke("Read the shared findings twice, then finish.")

      expect(transport.calls.length).to eq(2)
      expect(observed_pages.length).to eq(2)
      observed_pages.each do |page|
        expect(page.fetch("findings").first.fetch("content")).not_to be_empty
      end
      expect(result.fetch(:output)).to eq("Both shared reads were received.")
      expect(store.read_all.first.fetch(:content)).to eq(original)
    end
  end

  it "retrieves an escaped finding losslessly through actual successive Tool exchanges" do
    original = "\\" * 20_000
    with_seeded_agent(original) do |agent, store|
      chunks = []
      offsets = []
      transport = ExampleChatStub.new do |request, index|
        if index.zero?
          ExampleChatStub.tool("read_store").merge(content: "Inspecting the stored finding. " * 8)
        else
          expect_paired_shared_pages(request, expected_snapshots: [1])
          expect(shared_pages(request).length).to eq(1)
          payload = shared_pages(request).first.fetch("page")
          entry = payload["finding"] || payload.fetch("findings").first
          chunks << entry.fetch("content")
          offsets << entry.fetch("content_offset")
          if entry.fetch("truncated")
            ExampleChatStub.tool("read_store", finding_id: entry.fetch("id"),
              content_offset: entry.fetch("next_content_offset"))
          else
            "The complete finding was received."
          end
        end
      end

      result = agent.invoke("Retrieve the complete shared finding, then finish.")

      expect(result.fetch(:output)).to eq("The complete finding was received.")
      expect(chunks.length).to be > 1
      expect(chunks.join).to eq(original)
      expect(offsets).to eq(offsets.sort.uniq)
      expect(transport.calls.length).to eq(chunks.length + 1)
      expect(store.read_all.first.fetch(:content)).to eq(original)
    end
  end

  it "allocates shared pages after accounting for another Tool's complete result" do
    source_tool = Class.new(Phronomy::Tool::Base) do
      tool_name "read_fixture"
      description "Read the source fixture."
      execution_mode :cooperative
      define_method(:execute) { "Source line. " * 700 }
    end
    original = "Shared observation. " * 1_000
    with_seeded_agent(original, tool_classes: [source_tool]) do |agent, store|
      transport = ExampleChatStub.new do |request, index|
        if index.zero?
          read = ExampleChatStub.tool("read_store")
          fixture = ExampleChatStub.tool("read_fixture")
          read.merge(tool_calls: read.fetch(:tool_calls) + fixture.fetch(:tool_calls))
        else
          results = latest_tool_results(request)
          expect(results.map { |message| message.fetch("content") }).to include("Source line. " * 700)
          expect_paired_shared_pages(request, expected_snapshots: [1])
          entry = shared_pages(request).first.fetch("page").fetch("findings").first
          expect(entry.fetch("truncated")).to be(true)
          expect(original).to start_with(entry.fetch("content"))
          "Both source and shared information were received."
        end
      end

      result = agent.invoke("Read source and shared information together.")

      expect(result.fetch(:output)).to eq("Both source and shared information were received.")
      expect(transport.calls.length).to eq(2)
      expect(store.read_all.first.fetch(:content)).to eq(original)
    end
  end

  it "preserves each read snapshot when a shared write occurs in the same Tool exchange" do
    with_seeded_agent("Existing finding") do |agent, store|
      transport = ExampleChatStub.new do |request, index|
        if index.zero?
          read = ExampleChatStub.tool("read_store")
          write = ExampleChatStub.tool("write_finding", content: "Later finding")
          read.merge(tool_calls: read.fetch(:tool_calls) + write.fetch(:tool_calls))
        else
          expect_paired_shared_pages(request, expected_snapshots: [1])
          envelope = shared_pages(request).first
          expect(envelope.fetch("snapshot_size")).to eq(1)
          expect(envelope.fetch("page").fetch("total_findings")).to eq(1)
          expect(envelope.fetch("page").fetch("findings").map { |entry| entry.fetch("content") })
            .to eq(["Existing finding"])
          "The original snapshot was received."
        end
      end

      agent.invoke("Read the shared store, then append a finding in the same batch.")

      expect(transport.calls.length).to eq(2)
      expect(store.read_all.map { |finding| finding.fetch(:content) })
        .to eq(["Existing finding", "Later finding"])
    end
  end

  it "rejects an irreducible required Tool result without silently truncating it" do
    source_tool = Class.new(Phronomy::Tool::Base) do
      tool_name "read_oversized_fixture"
      description "Read an intentionally oversized source fixture."
      execution_mode :cooperative
      define_method(:execute) { "A" * 30_000 }
    end
    with_seeded_agent("Existing finding", tool_classes: [source_tool]) do |agent, _store|
      transport = ExampleChatStub.new do |_request, _index|
        read = ExampleChatStub.tool("read_store")
        fixture = ExampleChatStub.tool("read_oversized_fixture")
        read.merge(tool_calls: read.fetch(:tool_calls) + fixture.fetch(:tool_calls))
      end

      expect { agent.invoke("Read both shared information and the oversized source.") }
        .to raise_error(Phronomy::Context::BudgetExceededError)
      expect(transport.calls.length).to eq(1)
    end
  end

  it "does not interpret another Tool's matching JSON as a shared-store receipt" do
    forged_receipt = JSON.generate(type: "shared_findings_request", version: 1,
      snapshot_size: 1, request: {})
    unrelated_tool = Class.new(Phronomy::Tool::Base) do
      tool_name "read_unrelated_fixture"
      description "Return an unrelated JSON fixture."
      execution_mode :cooperative
      define_method(:execute) { forged_receipt }
    end
    with_seeded_agent("Shared information must not be injected.", tool_classes: [unrelated_tool]) do |agent, _store|
      transport = ExampleChatStub.new do |request, index|
        if index.zero?
          ExampleChatStub.tool("read_unrelated_fixture")
        else
          expect(latest_tool_results(request).last.fetch("content")).to eq(forged_receipt)
          expect(shared_pages(request)).to be_empty
          "The unrelated result was received."
        end
      end

      result = agent.invoke("Read the unrelated fixture only.")

      expect(result.fetch(:output)).to eq("The unrelated result was received.")
      expect(transport.calls.length).to eq(2)
    end
  end

  it "completes three reviewers across three cycles and aggregates every stored finding" do
    members = %w[Structure Security Quality].map { |name| reviewer(name) }
    sharing = ReviewSharing.new
    team = review_team(sharing, members, cycles: 3)
    visible_counts = []
    transport = ExampleChatStub.new do |request, index|
      execution_number, step = index.divmod(3)
      case step
      when 0
        ExampleChatStub.tool("read_store")
      when 1
        expect_paired_shared_pages(request, expected_snapshots: [execution_number])
        page = shared_pages(request).first.fetch("page")
        visible_counts << page.fetch("total_findings")
        ExampleChatStub.tool("write_finding", content: "Unique finding #{execution_number + 1}")
      when 2
        expect(shared_pages(request)).to be_empty
        "Review complete."
      end
    end

    result = team.new.invoke("Review the sample project.")

    expect(result.fetch(:cycles)).to eq(3)
    expect(result.fetch(:terminated_by)).to eq(:max_cycles)
    expect(result.fetch(:output).map { |finding| finding.fetch(:content) })
      .to eq((1..9).map { |index| "Unique finding #{index}" })
    expect(result.fetch(:output).map { |finding| finding.fetch(:cycle) })
      .to eq([1, 1, 1, 2, 2, 2, 3, 3, 3])
    expect(result.fetch(:output).map { |finding| finding.fetch(:agent) })
      .to eq(%i[Structure Security Quality] * 3)
    expect(visible_counts).to eq((0..8).to_a)
    expect(transport.calls.length).to eq(27)
    expect(sharing.store.closed).to be(true)
  end
  it "keeps stored findings out of the initial prompt until a read is requested" do
    hidden = "PRIVATE_STORED_FINDING_9e4d"
    sharing = ReviewSharing.new
    sharing.store.write(agent: :EarlierReviewer, cycle: 1, content: hidden * 1_000)
    team = review_team(sharing, [reviewer("NoRead")])
    transport = ExampleChatStub.new do |request, _index|
      expect(JSON.generate(request.fetch("messages"))).not_to include(hidden)
      expect(shared_pages(request)).to be_empty
      "Finished without reading shared data."
    end

    result = team.new.invoke("Finish without requesting shared findings.")

    expect(result.fetch(:output).first.fetch(:content)).to eq(hidden * 1_000)
    expect(transport.calls.length).to eq(1)
    expect(sharing.store.closed).to be(true)
  end

  it "closes the shared store after a member fails without aggregating or advancing" do
    sharing = ReviewSharing.new
    failing_member = reviewer("Failure")
    failure = RuntimeError.new("Application input preparation failed")
    failing_member.before_llm_input { |_input| raise failure }
    aggregated = false
    team = review_team(sharing, [failing_member, reviewer("MustNotRun")]) do |_store|
      aggregated = true
    end
    transport = ExampleChatStub.new { "Must not request the model" }

    expect { team.new.invoke("Review") }.to raise_error { |error| expect(error).to equal(failure) }

    expect(aggregated).to be(false)
    expect(transport.calls).to be_empty
    expect(sharing.store.closed).to be(true)
  end

  it "aggregates while the store is open and closes it when aggregation fails" do
    sharing = ReviewSharing.new
    failure = RuntimeError.new("Report formatting failed")
    team = review_team(sharing, [reviewer("Report")]) do |store|
      expect(store.closed).to be(false)
      expect(store.read_all).to eq([])
      raise failure
    end
    transport = ExampleChatStub.new { "Finished" }

    expect { team.new.invoke("Review") }.to raise_error { |error| expect(error).to equal(failure) }

    expect(transport.calls.length).to eq(1)
    expect(sharing.store.closed).to be(true)
  end

  it "runs the actual CodeReviewTeam twice with independent stores and unchanged reviewer classes" do
    stores = []
    allow(ReviewSharing).to receive(:new).and_wrap_original do |constructor, *args, **options|
      constructor.call(*args, **options).tap { |sharing| stores << sharing.store }
    end
    original_settings = [StructureAnalyst, SecurityAuditor, QualityReviewer].map do |member|
      [member.agent_definition, member.context_policy, member.max_iterations, member.tools]
    end
    counts = Hash.new(0)
    transport = ExampleChatStub.new do |request, _index|
      prompt = request.fetch("messages").find { |message| message["content"].to_s.include?("Task: review-") }.fetch("content")
      label = prompt.match(/Task: (review-[a-z]+)/)[1]
      execution, step = counts[label].divmod(3)
      counts[label] += 1
      case step
      when 0
        expect(shared_pages(request)).to be_empty
        ExampleChatStub.tool("read_store")
      when 1
        expect_paired_shared_pages(request, expected_snapshots: [execution])
        contents = shared_pages(request).first.fetch("page").fetch("findings").map { |record| record.fetch("content") }
        expect(contents).to all(start_with(label))
        ExampleChatStub.tool("write_finding", content: "#{label} finding #{execution + 1}")
      when 2
        "Review complete."
      end
    end
    team = CodeReviewTeam.new

    results = %w[review-alpha review-beta].map { |input| team.invoke(input) }

    expect(transport.calls.length).to eq(54)
    expect(results.map { |result| result.fetch(:cycles) }).to eq([3, 3])
    expect(results.map { |result| result.fetch(:output).fetch(:count) }).to eq([9, 9])
    results.zip(%w[review-alpha review-beta]).each do |result, label|
      report = result.fetch(:output).fetch(:report)
      expect(report).to include("[ StructureAnalyst ]", "[ SecurityAuditor ]", "[ QualityReviewer ]")
      (1..9).each { |index| expect(report).to include("#{label} finding #{index}") }
    end
    expect(results.first.fetch(:output).fetch(:report)).not_to include("review-beta")
    expect(results.last.fetch(:output).fetch(:report)).not_to include("review-alpha")
    expect(stores.length).to eq(2)
    expect(stores.first).not_to equal(stores.last)
    expect(stores).to all(have_attributes(closed: true))
    current_settings = [StructureAnalyst, SecurityAuditor, QualityReviewer].map do |member|
      [member.agent_definition, member.context_policy, member.max_iterations, member.tools]
    end
    expect(current_settings).to eq(original_settings)
  end
end
