# frozen_string_literal: true

# Shared InMemory persistence for all ChatAgent instances.
#
# NOTE: InMemory persistence is intentional for this demo. Conversation history
# lives in the Agent's Journal. Restarting the Rails process clears all history.
# In production, replace with a durable Persistence backend.
module PhronomyStore
  class << self
    attr_reader :persistence
  end

  @persistence = Phronomy::Persistence::InMemory.new
end
