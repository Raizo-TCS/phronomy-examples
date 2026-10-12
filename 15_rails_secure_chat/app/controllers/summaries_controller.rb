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

    result = Phronomy::Agent.open_scope do |agents|
      begin
        agent = agents.load(SecureChatAgent, agent_id, persistence: PhronomyStore.persistence)
      rescue Phronomy::AgentNotFoundError => error
        raise unless error.agent_id == agent_id

        next :absent
      end
      messages = PhronomyExamples::TranscriptMessages.read(agent)

      next :empty if messages.empty?

      summary_thread_id = "summary-#{agent_id}"
      app    = SummarizationGraph.compile(agents: agents)
      app.invoke(
        { messages: messages },
        config: { workflow_instance_id: summary_thread_id }
      )
    end
    case result
    when :absent
      render json: { error: "No active conversation." }, status: :unprocessable_entity
    when :empty
      render json: { error: "No messages to summarize." }, status: :unprocessable_entity
    else
      render json: { summary: result.summary }
    end
  rescue Phronomy::AgentBusyError
    render json: {error: "Conversation is busy. Please try again."}, status: :conflict
  rescue => e
    Rails.logger.error("SummarizationGraph error: #{e.class}: #{e.message}\n#{e.backtrace.first(10).join('\n')}")
    render json: { error: "Summarization failed. Please try again." }, status: :internal_server_error
  end
end
