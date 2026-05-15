# frozen_string_literal: true

# Feature C: Encrypted workflow checkpoint.
#
# A single-node workflow that summarises a conversation with an LLM.
# The workflow uses a StateStore::ActiveRecord backed by PHRONOMY_ENCRYPTOR,
# so state_json in phronomy_checkpoints is stored as AES-256-GCM ciphertext.
class SummarizationGraph
  class State
    include Phronomy::WorkflowContext

    # Input: conversation messages as an array of hashes { role:, content: }.
    field :messages, default: -> { [] }
    # Output: plain-text summary produced by the LLM.
    field :summary, default: ""
  end

  # Build the workflow with an encrypted ActiveRecord state store.
  #
  # @param encryptor [Phronomy::StateStore::Encryptor::Base]
  # @return [Phronomy::Workflow]
  def self.compile(encryptor:)
    checkpointer = Phronomy::StateStore::ActiveRecord.new(
      model_class: PhronomyCheckpoint,
      encryptor: encryptor
    )

    Phronomy::Workflow.define(State, state_store: checkpointer) do
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
