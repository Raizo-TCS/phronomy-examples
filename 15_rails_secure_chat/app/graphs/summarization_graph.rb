# frozen_string_literal: true

# Feature C: Single-node summarization workflow.
# The request owns Agent lifetimes. Workflow task states compose async work;
# errors reach the controller instead of becoming an empty successful summary.
class SummarizationGraph
  class State
    include Phronomy::WorkflowContext

    field :messages, default: -> { [] }
    field :summary, default: ""
  end

  class SummarizationAgent < Phronomy::Agent::Base
    agent_definition id: "example-15-summarization-agent", version: 1

    model        LLM_MODEL
    provider     :openai
    instructions "You are a helpful assistant that summarizes conversations concisely."
  end

  # @return [Phronomy::Workflow]
  def self.compile(agents:)
    Phronomy::Workflow.define(State) do
      initial :summarize

      task_state :summarize,
        start: ->(state) {
          text = state.messages.map { |m| "#{m['role']}: #{m['content']}" }.join("\n")
          prompt = "Summarize the following conversation in 3-5 concise sentences:\n\n#{text}"
          agents.create_async(SummarizationAgent).flat_map { |agent| agent.invoke_async(prompt) }
        },
        apply: ->(state, result) { state.merge(summary: result[:output].to_s) }

      transition from: :summarize, to: :__finish__
    end
  end
end
