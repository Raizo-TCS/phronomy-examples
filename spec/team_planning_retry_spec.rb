# frozen_string_literal: true

require "spec_helper"
require "ostruct"
require_relative "../21_team_coordinator/agents"

RSpec.describe "Blog planning validation and retries" do
  let(:valid_post) { {"sections" => Array.new(4) { {"content" => "A complete section. " * 4} }} }
  let(:accepted) { double("accepted team", stream: valid_post) }
  let(:execution) { OpenStruct.new(team_execution_id: "failed-plan") }
  let(:failure) do
    {status: "failed", error: {"class" => "Phronomy::ConfigurationError", "message" => "Cannot enqueue after finalize", "code" => "team.enqueue_after_finalize"}}
  end
  let(:error) { Phronomy::Error.new("Phronomy::ConfigurationError: Cannot enqueue after finalize") }
  let(:rejected) { double("rejected team", executions: [execution], result: failure) }

  before do
    allow($stderr).to receive(:puts)
    allow(rejected).to receive(:stream).and_raise(error)
  end

  it "forwards committed assignment observations and accepts four complete sections" do
    event = {type: :task_completed}
    expect(BlogWritingTeam).to receive(:new).once.and_return(accepted)
    expect(accepted).to receive(:stream).with("topic").and_yield(event).and_return(valid_post)
    observed = []
    expect(BlogWritingTeam.generate("topic") { |value| observed << value }).to eq(valid_post)
    expect(observed).to eq([event])
  end

  it "starts a fresh plan after a durably failed post-finalize rejection" do
    expect(BlogWritingTeam).to receive(:new).ordered.and_return(rejected)
    expect(BlogWritingTeam).to receive(:new).ordered.and_return(accepted)
    expect(BlogWritingTeam.generate("topic")).to eq(valid_post)
  end

  it "still retries a completed plan with fewer than four sections" do
    incomplete = double("incomplete team", stream: {"sections" => valid_post.fetch("sections").first(3)})
    expect(BlogWritingTeam).to receive(:new).ordered.and_return(incomplete)
    expect(BlogWritingTeam).to receive(:new).ordered.and_return(accepted)
    expect(BlogWritingTeam.generate("topic")).to eq(valid_post)
  end

  it "does not retry an unresolved execution even if its message mentions finalize" do
    uncertain = Phronomy::ExecutionRehydrationRequiredError.new("Cannot enqueue after finalize")
    allow(rejected).to receive(:stream).and_raise(uncertain)
    expect(rejected).not_to receive(:executions)
    expect(BlogWritingTeam).to receive(:new).once.and_return(rejected)
    expect { BlogWritingTeam.generate("topic") }.to raise_error { |caught| expect(caught).to equal(uncertain) }
  end

  it "propagates a different confirmed failure without retrying" do
    failure.fetch(:error)["code"] = "other.failure"
    expect(BlogWritingTeam).to receive(:new).once.and_return(rejected)
    expect { BlogWritingTeam.generate("topic") }.to raise_error { |caught| expect(caught).to equal(error) }
  end

  it "propagates a failure to read the durable outcome" do
    allow(rejected).to receive(:result).and_raise(IOError, "outcome unavailable")
    expect(BlogWritingTeam).to receive(:new).once.and_return(rejected)
    expect { BlogWritingTeam.generate("topic") }.to raise_error(IOError, "outcome unavailable")
  end

  it "preserves an error raised before a Team is constructed" do
    expect(BlogWritingTeam).to receive(:new).once.and_raise(error)
    expect { BlogWritingTeam.generate("topic") }.to raise_error { |caught| expect(caught).to equal(error) }
  end

  it "fails verification after the existing retry limit" do
    expect(BlogWritingTeam).to receive(:new).exactly(OutputValidator::MAX_RETRIES + 1).times.and_return(rejected)
    expect { BlogWritingTeam.generate("topic") }.to raise_error(SystemExit) { |exit| expect(exit.status).to eq(1) }
  end
  it "uses the reason code even when the diagnostic wording changes" do
    failure.fetch(:error)["message"] = "Task generation was already closed"
    expect(BlogWritingTeam).to receive(:new).ordered.and_return(rejected)
    expect(BlogWritingTeam).to receive(:new).ordered.and_return(accepted)
    expect(BlogWritingTeam.generate("topic")).to eq(valid_post)
  end

  it "does not infer a code from an old matching message" do
    failure.fetch(:error).delete("code")
    expect(BlogWritingTeam).to receive(:new).once.and_return(rejected)
    expect { BlogWritingTeam.generate("topic") }.to raise_error { |caught| expect(caught).to equal(error) }
  end

  it "does not retry an active outcome even with a matching code" do
    failure[:status] = "active"
    expect(BlogWritingTeam).to receive(:new).once.and_return(rejected)
    expect { BlogWritingTeam.generate("topic") }.to raise_error { |caught| expect(caught).to equal(error) }
  end
end
