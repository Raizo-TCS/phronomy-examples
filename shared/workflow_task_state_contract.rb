# frozen_string_literal: true

RSpec.shared_examples "persisted Workflow task states" do
  let(:state_class) do
    Class.new do
      include Phronomy::WorkflowContext
      field :answer, default: 0
    end
  end

  def build_task_workflow(store, start: ->(_) { Phronomy::TaskResult.completed(42) })
    Phronomy::Workflow.define(state_class, persistence: store) do
      initial :approval
      wait_state :approval
      task_state :working, start: start,
        apply: ->(state, answer) { state.merge(answer: answer) }
      transition from: :approval, on: :approved, to: :working
      transition from: :working, to: :__finish__
    end
  end

  it "resumes a saved business wait through a new pool and persists the Task result" do
    stores, pool = initial_storage
    first = build_task_workflow(stores.workflow)
    halted = first.invoke({}, config: {workflow_instance_id: "task-state-reload"})
    expect(halted.phase).to eq(:approval)
    pool.disconnect!
    reopened, = reopened_storage
    second = build_task_workflow(reopened.workflow)
    finished = second.send_event(state: halted, event: :approved)
    expect(finished.answer).to eq(42)
    saved = reopened.workflow.load("task-state-reload")
    expect(saved.fetch(:revision)).to eq(2)
    expect(saved.fetch(:snapshot).fetch("fields").fetch("answer")).to eq(42)
  end

  it "rejects a pending task checkpoint after reopening without repeating the operation" do
    stores, pool = initial_storage
    stores.workflow.save("task-state-pending", expected_revision: nil,
      snapshot: {fields: {answer: 7}, phase: "working"})
    pool.disconnect!
    reopened, = reopened_storage
    starts = []
    workflow = build_task_workflow(reopened.workflow,
      start: ->(_) { starts << true; Phronomy::TaskResult.completed(99) })
    expect { workflow.invoke({}, config: {workflow_instance_id: "task-state-pending"}) }
      .to raise_error(Phronomy::WorkflowTaskResumeError) { |error| expect(error.code).to eq("workflow.task_resume_unsupported") }
    expect(starts).to be_empty
    expect(reopened.workflow.load("task-state-pending").fetch(:revision)).to eq(1)
  end
end
