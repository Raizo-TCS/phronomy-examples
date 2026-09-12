# frozen_string_literal: true

require Rails.root.join("../shared/transcript_messages").expand_path.to_s

class SummariesController < ApplicationController
  # Feature C: summarize the current session's conversation via SummarizationGraph.
  def create
    agent_id = session[:agent_id]

    unless agent_id
      render json: { error: "No active conversation." }, status: :unprocessable_entity
      return
    end

    agent = SecureChatAgent.load(agent_id, persistence: PhronomyStore.persistence)
    messages = PhronomyExamples::TranscriptMessages.read(agent)

    if messages.empty?
      render json: { error: "No messages to summarize." }, status: :unprocessable_entity
      return
    end

    summary_thread_id = "summary-#{agent_id}"
    app    = SummarizationGraph.compile
    result = app.invoke(
      { messages: messages },
      config: { workflow_instance_id: summary_thread_id }
    )

    render json: { summary: result.summary }
  rescue Phronomy::Persistence::NotFoundError
    render json: { error: "No active conversation." }, status: :unprocessable_entity
  rescue => e
    Rails.logger.error("SummarizationGraph error: #{e.class}: #{e.message}\n#{e.backtrace.first(10).join('\n')}")
    render json: { error: "Summarization failed. Please try again." }, status: :internal_server_error
  end
end
