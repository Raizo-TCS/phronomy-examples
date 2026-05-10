# frozen_string_literal: true

# Feature C: Encrypted StateGraph checkpoint.
#
# A single-node graph that summarises a conversation with an LLM.
# The compiled graph uses StateStore::ActiveRecord backed by PHRONOMY_ENCRYPTOR,
# so state_json in phronomy_checkpoints is stored as AES-256-GCM ciphertext.
class SummarizationGraph
  class State
    include Phronomy::Graph::State

    # Input: conversation messages as an array of hashes { role:, content: }.
    field :messages, default: -> { [] }
    # Output: plain-text summary produced by the LLM.
    field :summary, default: ""
  end

  # Build and compile the graph with an encrypted ActiveRecord checkpointer.
  #
  # @param encryptor [Phronomy::StateStore::Encryptor::Base]
  # @return [Phronomy::Graph::CompiledGraph]
  def self.compile(encryptor:)
    graph = Phronomy::Graph::StateGraph.new(State)

    graph.add_node(:summarize) do |state|
      chat = RubyLLM.chat(model: LLM_MODEL, provider: :openai, assume_model_exists: true)
      text = state.messages.map { |m| "#{m["role"]}: #{m["content"]}" }.join("\n")
      prompt = "Summarize the following conversation in 3-5 concise sentences:\n\n#{text}"
      response = chat.ask(prompt)
      state.merge(summary: response.content)
    end

    graph.set_entry_point(:summarize)
    graph.add_edge(:summarize, Phronomy::Graph::StateGraph::FINISH)

    checkpointer = Phronomy::StateStore::ActiveRecord.new(
      model_class: PhronomyCheckpoint,
      encryptor:   encryptor
    )
    graph.compile(state_store: checkpointer)
  end
end
