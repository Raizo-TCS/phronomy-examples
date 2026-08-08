# frozen_string_literal: true

# Feature C: Single-node summarization workflow.
# The Workflow action fires invoke_async, then waits for the :summary_done
# signal rather than blocking the EventLoop thread with a synchronous invoke.
class SummarizationGraph
  class State
    include Phronomy::WorkflowContext

    field :messages, default: -> { [] }
    field :summary, default: ""
    # Stored so the invoke_async callback can signal back to this execution.
    field :wf_thread_id, default: ""
  end

  class SummarizationAgent < Phronomy::Agent::Base
    agent_definition id: "example-15-summarization-agent", version: 1

    model        LLM_MODEL
    provider     :openai
    instructions "You are a helpful assistant that summarizes conversations concisely."
  end

  # @return [Phronomy::Workflow]
  def self.compile
    wf_ref = nil

    wf_ref = Phronomy::Workflow.define(State) do
      initial :summarize

      # :summarize_waiting is a halt point; the Workflow resumes on :summary_done.
      wait_state :summarize_waiting

      entry :summarize, ->(state) {
        text = state.messages.map { |m| "#{m['role']}: #{m['content']}" }.join("\n")
        prompt = "Summarize the following conversation in 3-5 concise sentences:\n\n#{text}"

        # Fire the agent without blocking the EventLoop thread.
        SummarizationAgent.new.invoke_async(
          prompt,
          on_event: ->(event) {
            case event.type
            when :done
              wf_ref.signal(
                thread_id: state.wf_thread_id,
                event: :summary_done,
                payload: { summary: event.payload[:output].to_s }
              )
            when :error, :timeout, :cancelled
              wf_ref.signal(
                thread_id: state.wf_thread_id,
                event: :summary_done,
                payload: { summary: "" }
              )
            end
          }
        )
        state  # return state unchanged; auto-transition to :summarize_waiting
      }

      transition from: :summarize, to: :summarize_waiting

      transition(
        from: :summarize_waiting,
        to: :__finish__,
        on: :summary_done,
        action: ->(state, event) { state.merge(summary: event.payload[:summary]) }
      )
    end

    wf_ref
  end
end
