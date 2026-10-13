# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "stringio"
require_relative "../14_code_review/reviewers"

# Execute the real batch entry point with real Agents, Tasks and persistence.
# Only source discovery/splitting and the HTTP provider are controlled.
RSpec.describe "Batch review Agent ownership" do
  let(:script) { File.expand_path("../14_code_review/batch_review.rb", __dir__) }
  let(:library_root) { File.expand_path("../../phronomy/lib", File.dirname(script)) }

  around do |example|
    Dir.mktmpdir("batch-review") do |dir|
      @files = %w[first.rb second.rb].map do |name|
        path = File.join(dir, name)
        File.write(path, "puts :example\n" * 24)
        path
      end
      example.run
    end
  end

  before do
    @owners = []
    @scope_count = 0
    allow(Dir).to receive(:glob).and_call_original
    allow(Dir).to receive(:glob).with("#{library_root}/**/*.rb").and_return(@files)
    allow(Phronomy::Documents::Splitter::RecursiveSplitter).to receive(:new)
      .and_wrap_original do |constructor, **kwargs|
        splitter = constructor.call(**kwargs)
        allow(splitter).to receive(:split).and_return([{text: "chunk one"}, {text: "chunk two"}])
        splitter
      end
    allow(Phronomy::Agent).to receive(:open_scope).and_wrap_original do |open_scope, &body|
      # No prior chunk's owner may survive into the next chunk.
      expect_released
      @scope_count += 1
      open_scope.call do |scope|
        allow(scope).to receive(:create).and_wrap_original do |create, klass, **kwargs|
          @before_create&.call(klass)
          owner = create.call(klass, **kwargs)
          @owners << owner
          @after_create&.call(owner)
          owner
        end
        body.call(scope)
      end
    end
  end

  def run_batch
    @output = StringIO.new
    @warnings = StringIO.new
    original_stdout, original_stderr = $stdout, $stderr
    $stdout, $stderr = @output, @warnings
    load script, true
  ensure
    $stdout, $stderr = original_stdout, original_stderr
  end

  def expect_released
    @owners.each { |owner| expect(owner.class.get(owner.agent_id)).to be_nil }
  end

  it "releases each chunk's four reviewers while retaining all findings" do
    stub = ExampleChatStub.new { |_body, index| "finding #{index + 1}" }
    run_batch
    expect(@scope_count).to eq(4)
    expect(@owners.length).to eq(16)
    expect(stub.calls.length).to eq(16)
    expect_released
    expect(@output.string).to include("Total: 2 files reviewed", "[Security]", "[Performance]",
      "[Readability]", "[Abstraction Consistency]")
    (1..16).each { |index| expect(@output.string).to include("finding #{index}\n") }
    expect(@warnings.string).to be_empty
  end

  it "preserves partial success and warnings after an asynchronous provider failure" do
    stub = ExampleChatStub.new do |_body, index|
      raise ArgumentError, "provider rejected request" if index.zero?
      "retained finding #{index}"
    end
    run_batch
    expect(stub.calls.length).to eq(16)
    expect(@owners.length).to eq(16)
    expect_released
    expect(@warnings.string).to include("provider rejected request", "chunk 1]")
    expect(@output.string).to include("retained finding 15", "Total: 2 files reviewed")
  end

  it "releases already acquired owners without starting work when construction fails" do
    failure = RuntimeError.new("reviewer construction failed")
    @before_create = ->(klass) { raise failure if klass == PerformanceReviewerAgent }
    stub = ExampleChatStub.new { "unexpected call" }
    expect { run_batch }.to raise_error { |error| expect(error).to equal(failure) }
    expect(@owners.length).to eq(1)
    expect(stub.calls).to be_empty
    expect_released
  end

  it "waits for started work before release and preserves a synchronous start failure" do
    failure = RuntimeError.new("reviewer start failed")
    waited = false
    @after_create = lambda do |owner|
      if owner.is_a?(SecurityReviewerAgent)
        allow(owner).to receive(:invoke_async).and_wrap_original do |invoke, *args|
          task = invoke.call(*args)
          allow(task).to receive(:wait_result).and_wrap_original do |wait|
            result = wait.call
            waited = true
            result
          end
          task
        end
      elsif owner.is_a?(PerformanceReviewerAgent)
        allow(owner).to receive(:invoke_async).and_raise(failure)
      end
    end
    stub = ExampleChatStub.new { "completed started work" }
    expect { run_batch }.to raise_error { |error| expect(error).to equal(failure) }
    expect(waited).to be(true)
    expect(stub.calls.length).to eq(1)
    expect(@owners.length).to eq(4)
    expect_released
  end
end
