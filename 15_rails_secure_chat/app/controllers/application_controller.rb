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
end
