# frozen_string_literal: true

class SummariesController < ApplicationController
  # Feature C: summarize the current session's conversation via SummarizationGraph.
  def create
    agent_id = session[:agent_id]

    unless agent_id
      render json: { error: "No active conversation." }, status: :unprocessable_entity
      return
    end

    agent = SecureChatAgent.load(agent_id, persistence: PhronomyStore.persistence)
    messages = agent.transcript.filter_map do |record|
      next unless %i[user assistant].include?(record.role)
      content_raw = PhronomyStore.persistence.contents.fetch_text(record.content_ref)
      content_text = begin
        JSON.parse(content_raw)["content"] || content_raw
      rescue JSON::ParserError
        content_raw
      end
      { "role" => record.role.to_s, "content" => content_text }
    end

    if messages.empty?
      render json: { error: "No messages to summarize." }, status: :unprocessable_entity
      return
    end

    summary_thread_id = "summary-#{agent_id}"
    app    = SummarizationGraph.compile
    result = app.invoke(
      { messages: messages, wf_thread_id: summary_thread_id },
      config: { thread_id: summary_thread_id }
    )

    render json: { summary: result.summary }
  rescue Phronomy::Persistence::NotFoundError
    render json: { error: "No active conversation." }, status: :unprocessable_entity
  rescue => e
    Rails.logger.error("SummarizationGraph error: #{e.class}: #{e.message}\n#{e.backtrace.first(10).join('\n')}")
    render json: { error: "Summarization failed. Please try again." }, status: :internal_server_error
  end
end
