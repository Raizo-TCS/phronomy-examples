# frozen_string_literal: true

require "rails_helper"

RSpec.describe "CVE scan Job notifications" do
  let(:scan) { Scan.create!(cve_ids: ["CVE-2023-52160"], status: "pending") }
  let(:sent) { [] }
  let(:server) { ActionCable.server }
  let(:answer) do
    {decision: "done", vulnerability_status: {"CVE-2023-52160" => "not_vulnerable"}}.to_json
  end

  before do
    allow(server).to receive(:broadcast) do |stream, payload|
      expect(Phronomy::Runtime.in_event_loop_context?).to be(false)
      expect(Rails.application.executor.active?).to be(true)
      sent << [stream, payload]
    end
    allow(CveScanner).to receive(:`).and_return("24.04\n")
    allow_any_instance_of(CveScanner::UbuntuCveScraperTool).to receive(:execute)
      .and_return({priority: "medium", packages: {"sample" => {}}, description: "test"}.to_json)
    allow_any_instance_of(CveScanner::CommandExecutorTool).to receive(:execute).and_return("checked")
  end

  after { Phronomy.reset_runtime! }

  def events
    sent.map(&:last)
  end

  def expect_same_error(error, &block)
    expect(&block).to raise_error { |caught| expect(caught).to equal(error) }
  end

  it "routes real Workflow/Agent/Tool events off EventLoop, drains at a halt, then resumes with a new scope" do
    stub = NotificationChatStub.new do |body, index|
      if index.zero?
        name = body.fetch("tools").first.fetch("function").fetch("name")
        {role: "assistant", content: nil, tool_calls: [{id: "notification-tool", type: "function",
          function: {name: name, arguments: {url: "https://example.invalid/reference"}.to_json}}]}
      else
        answer
      end
    end
    scopes = []
    allow(CveScanner::Notifications).to receive(:open).and_wrap_original do |original, **kwargs, &block|
      original.call(**kwargs) { |delivery| scopes << delivery; block.call(delivery) }
    end

    Rails.application.executor.wrap { ScanJob.new.perform(scan.id, scan.cve_ids) }
    expect(scan.reload.status).to eq("awaiting_followup")
    expect(events.last[:type]).to eq("awaiting_followup")
    expect(events.map { |event| event[:type] }).to include("status", "log", "agent_step", "chat_turn_start", "llm_token", "chat_turn_done", "scan_report")
    expect(events.filter_map { |event| event[:subtype] }).to include("tool_call", "tool_result")
    start_index = events.index { |event| event[:type] == "chat_turn_start" }
    done_index = events.index { |event| event[:type] == "chat_turn_done" }
    token_indices = events.each_index.select { |i| events[i][:type] == "llm_token" }
    expect(token_indices).not_to be_empty
    expect(token_indices).to all(be > start_index)
    expect(token_indices).to all(be < done_index)
    expect { scopes.first.publish(type: "late") }.to raise_error(Phronomy::Integrations::OrderedEventDelivery::ClosedError)

    boundary = events.length
    Rails.application.executor.wrap { ScanFollowupJob.new.perform(scan.id, "done") }
    expect(scan.reload.status).to eq("done")
    expect(events.drop(boundary).map { |event| event[:type] }).to eq(%w[status followup_answer done])
    expect(scopes.length).to eq(2)
    expect(scopes.first).not_to equal(scopes.last)
    expect(stub.calls.length).to eq(2)
    expect(sent.map(&:first).uniq).to eq(["scan_#{scan.id}"])
  end

  it "drains approval notifications and uses a fresh publisher for the approved continuation" do
    stub = NotificationChatStub.new do |_body, index|
      index.zero? ? {decision: "need_more", proposed_commands: ["uname -r"]}.to_json : answer
    end
    ScanJob.new.perform(scan.id, scan.cve_ids)
    expect(scan.reload.status).to eq("awaiting_check")
    expect(events.last).to include(type: "awaiting_approval", approval_type: "check", commands: ["uname -r"])
    boundary = events.length
    ScanResumeJob.new.perform(scan.id, approval_type: "check", approved_commands: ["uname -r"], user_note: " approved ")
    expect(scan.reload.status).to eq("awaiting_followup")
    expect(scan.state_json["user_notes"]).to include("approved")
    expect(events.drop(boundary).first[:type]).to eq("status")
    expect(events.last[:type]).to eq("awaiting_followup")
    expect(stub.calls.length).to eq(2)
  end

  it "delivers a real ChatAgent's streamed tokens before its final answer" do
    stub = NotificationChatStub.new { "A streamed answer with several chunks." }
    Rails.application.executor.wrap { ScanChatJob.new.perform(scan.id, "question") }
    expect(events.first[:type]).to eq("chat_turn_start")
    expect(events.last).to include(type: "chat_turn_done", content: "A streamed answer with several chunks.")
    expect(events.select { |event| event[:type] == "llm_token" }.map { |event| event[:token] }.join)
      .to eq("A streamed answer with several chunks.")
    expect(stub.calls.length).to eq(1)
  end

  it "fails a Chat Job with the original business error rather than swallowing it" do
    failure = IOError.new("Agent construction failed")
    allow(Phronomy::Agent).to receive(:open_scope).and_wrap_original do |original, &block|
      original.call do |agents|
        allow(agents).to receive(:create).with(CveScanner::ChatAgent, anything).and_raise(failure)
        block.call(agents)
      end
    end
    expect_same_error(failure) { ScanChatJob.new.perform(scan.id, "question") }
    expect(events.map { |event| event[:type] }).to eq(%w[chat_turn_start error])
    expect(events.last[:message]).to eq(failure.message)
  end

  {
    awaiting_check_approval: ["awaiting_check", "awaiting_approval"],
    awaiting_remediation_approval: ["awaiting_remediation", "awaiting_approval"],
    awaiting_followup: ["awaiting_followup", "awaiting_followup"],
    completed: ["done", "done"]
  }.each do |phase, (status, final_event)|
    [:publish, :drain].each do |failure_at|
      it "preserves saved #{status} when final #{failure_at} fails" do
        state = double("result state", halted?: phase != :completed, phase: phase,
          proposed_checks: ["check"], proposed_remediations: ["remediation"],
          check_iteration: 1, remediation_iteration: 2, to_h: {"saved" => "state"},
          workflow_instance_id: "state-#{scan.id}", vulnerability_status: {}, cve_infos: {},
          vulnerability_reasoning: {}, messages: [])
        allow(CveScanner).to receive(:build_graph).and_return(double("graph", invoke: state))
        failure = IOError.new("final #{failure_at} failed")
        if failure_at == :publish
          allow(CveScanner::Notifications).to receive(:open).and_wrap_original do |original, **kwargs, &block|
            original.call(**kwargs) do |delivery|
              allow(delivery).to receive(:publish).and_wrap_original do |publish, payload|
                raise failure if payload[:type] == final_event
                publish.call(payload)
              end
              block.call(delivery)
            end
          end
        else
          allow(server).to receive(:broadcast) do |_stream, payload|
            raise failure if payload[:type] == final_event
          end
        end
        expect_same_error(failure) { ScanJob.new.perform(scan.id, scan.cve_ids) }
        expect(scan.reload.status).to eq(status)
        if phase == :completed
          expect(scan.result_json).to include("messages" => [])
        else
          expect(scan.state_json).to include("saved" => "state", "phase" => phase.to_s)
        end
      end
    end
  end

  it "marks an unfinished scan failed and preserves its error across status-save and delivery failures" do
    primary = IOError.new("workflow failed")
    graph = double("graph")
    allow(graph).to receive(:invoke).and_raise(primary)
    allow(CveScanner).to receive(:build_graph).and_return(graph)
    allow(Scan).to receive(:find).with(scan.id).and_return(scan)
    allow(scan).to receive(:update!).and_call_original
    allow(scan).to receive(:update!).with(status: "error").and_raise(IOError, "save failed")
    allow(Rails.logger).to receive(:error).and_raise(IOError, "log failed")
    allow(server).to receive(:broadcast) do |_stream, payload|
      raise IOError, "error delivery failed" if payload[:type] == "error"
    end
    expect_same_error(primary) { ScanJob.new.perform(scan.id, scan.cve_ids) }
  end

  it "saves error status for a business failure before a successful final state was persisted" do
    primary = IOError.new("workflow failed")
    graph = double("graph")
    allow(graph).to receive(:invoke).and_raise(primary)
    allow(CveScanner).to receive(:build_graph).and_return(graph)
    expect_same_error(primary) { ScanJob.new.perform(scan.id, scan.cve_ids) }
    expect(scan.reload.status).to eq("error")
    expect(events.last).to eq(type: "error", message: primary.message)
  end

  it "returns the original error when the initial Scan lookup fails" do
    primary = ActiveRecord::RecordNotFound.new("missing scan")
    allow(Scan).to receive(:find).with(999).and_raise(primary)
    expect_same_error(primary) { ScanJob.new.perform(999, []) }
    expect(sent).to eq([["scan_999", {type: "error", message: "missing scan"}]])
  end

  it "does no work or notification when either resume has no saved state" do
    expect(CveScanner).not_to receive(:build_graph)
    ScanJob.resume(scan.id, approval_type: "check", approved_commands: [])
    ScanJob.resume_followup(scan.id, message: "question")
    expect(scan.reload.status).to eq("pending")
    expect(events).to be_empty
  end

  it "does not add an automatic retry policy to the four Job entry points" do
    [ScanJob, ScanChatJob, ScanResumeJob, ScanFollowupJob].each do |job|
      expect(job.rescue_handlers).to eq(ApplicationJob.rescue_handlers)
    end
  end
  context "Agent ownership and notification completion" do
    let(:owned) { [] }

    before do
      allow(Phronomy::Agent).to receive(:open_scope).and_wrap_original do |original, &block|
        original.call do |agents|
          [:create, :create_async].each do |method|
            allow(agents).to receive(method).and_wrap_original do |materialize, *args, **kwargs|
              value = materialize.call(*args, **kwargs)
              if value.is_a?(Phronomy::TaskResult)
                value.map { |agent| owned << agent; agent }
              else
                owned << value
                value
              end
            end
          end
          block.call(agents)
        end
      end
    end

    it "keeps the ChatAgent owned until the final transport call returns" do
      NotificationChatStub.new { "answer" }
      allow(server).to receive(:broadcast) do |stream, payload|
        if payload[:type] == "chat_turn_done"
          expect(owned.length).to eq(1)
          expect(owned.first.class.get(owned.first.agent_id)).to equal(owned.first)
        end
        sent << [stream, payload]
      end
      ScanChatJob.new.perform(scan.id, "question")
      expect(events.last[:type]).to eq("chat_turn_done")
      expect(owned.length).to eq(1)
      expect(owned.first.class.get(owned.first.agent_id)).to be_nil
    end

    it "releases all completed Workflow Agents at a halt before the next Job" do
      NotificationChatStub.new { answer }
      ScanJob.new.perform(scan.id, scan.cve_ids)
      expect(scan.reload.status).to eq("awaiting_followup")
      expect(owned).not_to be_empty
      owned.each { |agent| expect(agent.class.get(agent.agent_id)).to be_nil }
      before_resume = owned.length
      ScanJob.resume_followup(scan.id, message: "done")
      expect(scan.reload.status).to eq("done")
      expect(owned.length).to eq(before_resume)
    end

    it "preserves a saved halt and final notification if Agent cleanup fails" do
      failure = IOError.new("Agent Store check failed")
      NotificationChatStub.new { answer }
      allow(server).to receive(:broadcast) do |stream, payload|
        if payload[:type] == "awaiting_followup"
          owned.each { |agent| allow(agent).to receive(:unload!).and_raise(failure) }
        end
        sent << [stream, payload]
      end
      expect {
        ScanJob.new.perform(scan.id, scan.cve_ids)
      }.to raise_error(Phronomy::Agent::ScopeCleanupError) do |error|
        expect(error.failures.map { |entry| entry.fetch(:error) }).to all(equal(failure))
      end
      expect(scan.reload.status).to eq("awaiting_followup")
      expect(events.last[:type]).to eq("awaiting_followup")
      expect(events.none? { |event| event[:type] == "error" }).to be(true)
    end
    it "preserves the delivery error when Agent cleanup also fails" do
      primary = IOError.new("final delivery failed")
      secondary = IOError.new("cleanup failed")
      NotificationChatStub.new { "answer" }
      allow(server).to receive(:broadcast) do |_stream, payload|
        if payload[:type] == "chat_turn_done"
          allow(owned.first).to receive(:unload!).and_raise(secondary)
          raise primary
        end
      end
      expect_same_error(primary) { ScanChatJob.new.perform(scan.id, "question") }
      expect(owned.first.class.get(owned.first.agent_id)).to equal(owned.first)
    end

  end
end
