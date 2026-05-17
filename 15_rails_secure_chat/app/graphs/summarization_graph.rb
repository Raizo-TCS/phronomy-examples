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

  # Build the summarization workflow.
  #
  # @return [Phronomy::Workflow]
  def self.compile
    Phronomy::Workflow.define(State) do
      initial :summarize

      state :summarize, action: ->(state) {
        chat = RubyLLM.chat(model: LLM_MODEL, provider: :openai, assume_model_exists: true)
        text = state.messages.map { |m| "#{m["role"]}: #{m["content"]}" }.join("\n")
        prompt = "Summarize the following conversation in 3-5 concise sentences:\n\n#{text}"
        response = chat.ask(prompt)
        state.merge(summary: response.content)
      }
    end
  end
end
