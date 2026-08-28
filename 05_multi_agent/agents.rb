# frozen_string_literal: true

require_relative "../shared/llm_config"
require "phronomy"

# max_output_tokens sets the Phronomy context-budget output reserve for each
# agent. Phronomy 0.19.x does not implement provider-specific output-token
# mapping; it is forwarded only when RubyLLM provides a normalised API for it.
# Prompt instructions are responsible for controlling actual output length here.
RESEARCHER_CONTEXT_RESERVE = 512
WRITER_CONTEXT_RESERVE     = 2048
ORCHESTRATOR_CONTEXT_RESERVE = 2048

class ResearcherAgent < Phronomy::Agent::Base
  agent_definition id: "example-05-researcher-agent", version: 1

  model LLMConfig::MODEL
  provider LLMConfig::PROVIDER
  max_output_tokens RESEARCHER_CONTEXT_RESERVE
  instructions "You are a technical researcher. " \
               "Return exactly 5 concise bullet points on the given topic. " \
               "Keep each bullet to one or two sentences."
end

class WriterAgent < Phronomy::Agent::Base
  agent_definition id: "example-05-writer-agent", version: 1

  model LLMConfig::MODEL
  provider LLMConfig::PROVIDER
  max_output_tokens WRITER_CONTEXT_RESERVE
  instructions "You are a technical writer. " \
               "Write a concise technical article of about 250-350 words based on the instructions given. " \
               "Return only the article body."
end

# Agent-as-Tool wrappers: expose sub-agents as callable tools so the
# orchestrator LLM can invoke them on demand rather than in a fixed order.
class ResearchTool < Phronomy::Tool::Base
  description "Research a topic and return key findings as bullet points."
  param :topic, type: :string, desc: "The topic to research"

  def execute(topic:)
    t0 = Time.now
    puts "  [ResearchTool] input: #{topic.inspect[0, 80]}"
    result = ResearcherAgent.new.invoke(topic)[:output]
    $accumulated_tool_chars = ($accumulated_tool_chars || 0) + result.length
    puts "  [ResearchTool] done: #{result.length} chars in #{(Time.now - t0).round(1)}s (total tool chars: #{$accumulated_tool_chars})"
    result
  end
end

class WriteTool < Phronomy::Tool::Base
  description "Write a concise technical article given research notes and a writing brief."
  param :instructions, type: :string, desc: "Writing brief including research notes"

  def execute(instructions:)
    t0 = Time.now
    puts "  [WriteTool] input: #{instructions.length} chars"
    puts "  [WriteTool] first 120: #{instructions[0, 120].inspect}"
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
  max_output_tokens ORCHESTRATOR_CONTEXT_RESERVE
  tools(
    ResearchTool => nil,
    WriteTool => nil
  )
  instructions "You are an orchestrator responsible for producing a concise technical blog post. " \
               "Use the research tool to gather bullet-point notes, then the write tool to produce the article. " \
               "The writer has been instructed to produce a concise article (250-350 words). " \
               "After the write tool returns the article, output that article text only. " \
               "Do not expand, summarize, or add commentary."
end
