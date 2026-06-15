# frozen_string_literal: true

# Feature C: Single-node summarization workflow.
# v0.3.0: StateStore::ActiveRecord removed. The workflow runs synchronously
# without checkpoint persistence.
class SummarizationGraph
  class State
    include Phronomy::WorkflowContext

    # Input: conversation messages as an array of hashes { role:, content: }.
    field :messages, default: -> { [] }
    # Output: plain-text summary produced by the LLM.
    field :summary, default: ""
  end

  class SummarizationAgent < Phronomy::Agent::Base
    model        LLM_MODEL
    provider     :openai
    instructions "You are a helpful assistant that summarizes conversations concisely."
  end

  # Build the summarization workflow.
  #
  # @return [Phronomy::Workflow]
  def self.compile
    Phronomy::Workflow.define(State) do
      initial :summarize

      state :summarize, action: ->(state) {
        text = state.messages.map { |m| "#{m["role"]}: #{m["content"]}" }.join("\n")
        prompt = "Summarize the following conversation in 3-5 concise sentences:\n\n#{text}"
        result = SummarizationAgent.new.invoke(prompt)
        state.merge(summary: result[:output])
      }
    end
  end
end
