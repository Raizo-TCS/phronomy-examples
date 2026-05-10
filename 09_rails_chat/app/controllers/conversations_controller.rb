# frozen_string_literal: true

class ConversationsController < ApplicationController
  def index
    @thread_id = session[:thread_id]
    @messages  = @thread_id ? PhronomyMessage.where(thread_id: @thread_id).order(:created_at) : []
  end

  def create
    session[:thread_id] = SecureRandom.uuid
    redirect_to root_path
  end
end
