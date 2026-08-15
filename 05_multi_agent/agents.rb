# frozen_string_literal: true

require_relative "../shared/llm_config"
require "phronomy"

# Reasonable output budget: ResearcherAgent produces bullet notes, WriterAgent
# writes a short article. Both are bounded so the slow local LLM finishes promptly.
RESEARCHER_MAX_TOKENS = 512  # ~400 words for bullet notes
WRITER_MAX_TOKENS     = 2048 # ~1500 words for blog article

class ResearcherAgent < Phronomy::Agent::Base
  agent_definition id: "example-05-researcher-agent", version: 1

  model LLMConfig::MODEL
  provider LLMConfig::PROVIDER
  max_output_tokens RESEARCHER_MAX_TOKENS
  instructions "You are a technical researcher. " \
               "List about 5 key points on the given topic as concise bullet points."
end

class WriterAgent < Phronomy::Agent::Base
  agent_definition id: "example-05-writer-agent", version: 1

  model LLMConfig::MODEL
  provider LLMConfig::PROVIDER
  max_output_tokens WRITER_MAX_TOKENS
  instructions "You are a technical writer. " \
               "Write a readable technical blog post based on the instructions given. " \
               "Return only the article body."
end

# Agent-as-Tool wrappers: expose sub-agents as callable tools so the
# orchestrator LLM can invoke them on demand rather than in a fixed order.
class ResearchTool < Phronomy::Agent::Context::Capability::Base
  description "Research a topic and return key findings as bullet points."
  param :topic, type: :string, desc: "The topic to research"

  def execute(topic:)
    t0 = Time.now
    puts "  [ResearchTool] input: #{topic.inspect[0, 80]}"
    puts "  [ResearchTool] ResearcherAgent max_output_tokens=#{RESEARCHER_MAX_TOKENS}"
    result = ResearcherAgent.new.invoke(topic)[:output]
    $accumulated_tool_chars = ($accumulated_tool_chars || 0) + result.length
    puts "  [ResearchTool] done: #{result.length} chars in #{(Time.now - t0).round(1)}s (total tool chars: #{$accumulated_tool_chars})"
    result
  end
end

class WriteTool < Phronomy::Agent::Context::Capability::Base
  description "Write a technical blog post given research notes and a writing brief."
  param :instructions, type: :string, desc: "Writing brief including research notes"

  def execute(instructions:)
    t0 = Time.now
    puts "  [WriteTool] input: #{instructions.length} chars"
    puts "  [WriteTool] first 120: #{instructions[0, 120].inspect}"
    puts "  [WriteTool] WriterAgent max_output_tokens=#{WRITER_MAX_TOKENS}"
    result = WriterAgent.new.invoke(instructions)[:output]
    $accumulated_tool_chars = ($accumulated_tool_chars || 0) + result.length
    puts "  [WriteTool] done: #{result.length} chars in #{(Time.now - t0).round(1)}s (total tool chars: #{$accumulated_tool_chars})"
    result
  end
end

class OrchestratorAgent < Phronomy::Agent::Base
  agent_definition id: "example-05-orchestrator-agent", version: 2

  model LLMConfig::MODEL
  provider LLMConfig::PROVIDER
  # Orchestrator needs tokens for tool calls AND for returning the article.
  max_output_tokens 2048
  tools(
    ResearchTool => nil,
    WriteTool => nil
  )
  instructions "You are an orchestrator responsible for producing a high-quality technical blog post. " \
               "Use the research tool to gather information, then use the write tool to produce the article. " \
               "After write tool returns the article, output ONLY the article text verbatim with no additional commentary."
end
