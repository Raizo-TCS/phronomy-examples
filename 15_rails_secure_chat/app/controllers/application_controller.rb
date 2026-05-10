# frozen_string_literal: true

class ApplicationController < ActionController::Base
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Feature B: Assign a stable UUID to every browser session as the user identity.
  before_action :ensure_user_id

  private

  def ensure_user_id
    session[:user_id]    ||= SecureRandom.uuid
    session[:session_id] ||= SecureRandom.uuid
  end

  # Return a ConversationManager backed by PhronomyMessage (acts_as_phronomy_message DSL).
  # The manager uses the legacy storage interface which is compatible with the
  # model class alone (no raw_model_class required for basic usage).
  def build_memory
    PhronomyMessage.phronomy_memory
  end

  # Feature D: purge messages older than PHRONOMY_MEMORY_TTL seconds for a thread.
  # Called explicitly before each LLM call so stale context is stripped.
  def purge_stale_messages(thread_id)
    cutoff = Time.now - PHRONOMY_MEMORY_TTL
    PhronomyMessage
      .where(thread_id: thread_id)
      .where("created_at < ?", cutoff)
      .delete_all
  end
end
