# frozen_string_literal: true

class SummariesController < ApplicationController
  # Feature C: run the SummarizationGraph with an encrypted checkpointer.
  # The graph checkpoint (state_json) is stored AES-256-GCM encrypted in
  # phronomy_checkpoints via PHRONOMY_ENCRYPTOR.
  def create
    thread_id = session[:thread_id]

    unless thread_id
      render json: { error: "No active conversation." }, status: :unprocessable_entity
      return
    end

    messages = PhronomyMessage
      .where(thread_id: thread_id)
      .order(:created_at)
      .map { |m| { "role" => m.role, "content" => m.content } }

    if messages.empty?
      render json: { error: "No messages to summarize." }, status: :unprocessable_entity
      return
    end

    app    = SummarizationGraph.compile
    result = app.invoke(
      { messages: messages },
      config: { thread_id: "summary-#{thread_id}" }
    )

    render json: { summary: result.summary }
  rescue => e
    Rails.logger.error("SummarizationGraph error: #{e.class}: #{e.message}\n#{e.backtrace.first(10).join("\n")}")
    render json: { error: "Summarization failed. Please try again." }, status: :internal_server_error
  end
end
