# frozen_string_literal: true

require_relative "../shared/llm_config"
require "phronomy"

class ResearcherAgent < Phronomy::Agent::Base
  model LLMConfig::MODEL
  provider LLMConfig::PROVIDER
  instructions "You are a technical researcher. " \
               "List about 5 key points on the given topic as concise bullet points."
end

class WriterAgent < Phronomy::Agent::Base
  model LLMConfig::MODEL
  provider LLMConfig::PROVIDER
  instructions "You are a technical writer. " \
               "Write a readable technical blog post based on the instructions given. " \
               "Return only the article body."
end

# Agent-as-Tool wrappers: expose sub-agents as callable tools so the
# orchestrator LLM can invoke them on demand rather than in a fixed order.

class ResearchTool < Phronomy::Tool::Base
  description "Research a topic and return key findings as bullet points."
  param :topic, type: :string, desc: "The topic to research"

  def execute(topic:)
    puts "  [ResearchTool] topic=#{topic}"
    ResearcherAgent.new.invoke(topic)[:output]
  end
end

class WriteTool < Phronomy::Tool::Base
  description "Write a technical blog post given research notes and a writing brief."
  param :instructions, type: :string, desc: "Writing brief including research notes"

  def execute(instructions:)
    puts "  [WriteTool] writing article..."
    WriterAgent.new.invoke(instructions)[:output]
  end
end

class OrchestratorAgent < Phronomy::Agent::Base
  model LLMConfig::MODEL
  provider LLMConfig::PROVIDER
  tools ResearchTool, WriteTool
  instructions "You are an orchestrator responsible for producing a high-quality technical blog post. " \
               "Use the research tool to gather information, then use the write tool to produce the article. " \
               "Return the final article text."
end
