# frozen_string_literal: true

# Legacy model retained for database compatibility only.
# Conversation history is now stored in the Agent Journal via PhronomyStore.
# This class is no longer used by the application.
class PhronomyMessage < ApplicationRecord
end
