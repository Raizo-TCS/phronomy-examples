# frozen_string_literal: true

class ConversationsController < ApplicationController
  def index
    @thread_id = session[:thread_id]
    @user_id   = session[:user_id]
    @messages  = @thread_id ? PhronomyMessage.where(thread_id: @thread_id).order(:created_at) : []
  end

  def create
    session[:thread_id] = SecureRandom.uuid
    redirect_to root_path
  end

  # Feature D: purge — permanently erase all data for the current thread.
  def destroy
    thread_id = params[:id]
    if thread_id.present?
      PhronomyMessage.where(thread_id: thread_id).delete_all
      session.delete(:thread_id)
    end
    redirect_to root_path, notice: "Conversation deleted."
  end
end
