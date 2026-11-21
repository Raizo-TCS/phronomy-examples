# frozen_string_literal: true

require_relative "../shared/llm_config"
require "phronomy"
require_relative "validation"

require_relative "budget"

class ResearcherAgent < Phronomy::Agent::Base
  agent_definition id: "example-05-researcher-agent", version: 2

  model LLMConfig::MODEL
  provider LLMConfig::PROVIDER
  before_llm_input Example05Budget.method(:patch)
  context_policy Example05InputPolicy.new
  instructions "You are a technical researcher. " \
               "Return exactly 5 concise bullet points on the given topic. " \
               "Keep each bullet to one or two sentences."
end

class WriterAgent < Phronomy::Agent::Base
  agent_definition id: "example-05-writer-agent", version: 2

  model LLMConfig::MODEL
  provider LLMConfig::PROVIDER
  before_llm_input Example05Budget.method(:patch)
  context_policy Example05InputPolicy.new
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
    result = Phronomy::Agent.open_scope { |agents| agents.create(ResearcherAgent).invoke_async(topic) }[:output]
    Example05Validation.require_text!(result, "Researcher returned no final-answer text")
    $accumulated_tool_chars = ($accumulated_tool_chars || 0) + result.length
    puts "  [ResearchTool] done: #{result.length} chars in #{(Time.now - t0).round(1)}s (total tool chars: #{$accumulated_tool_chars})"
    result
  end
end

class WriteTool < Phronomy::Tool::Base
  description "Write a concise technical article given research notes and a writing brief."
  param :instructions, type: :string, desc: "Writing brief"
  param :research_notes, type: :string, desc: "Copy the complete research Tool result verbatim"

  def execute(instructions:, research_notes:)
    Example05Validation.require_text!(research_notes, "Writing requires nonblank research notes")
    t0 = Time.now
    puts "  [WriteTool] input: #{instructions.length} chars"
    puts "  [WriteTool] first 120: #{instructions[0, 120].inspect}"
    prompt = "Writing brief:\n#{instructions}\n\nResearch notes:\n#{research_notes}"
    puts "  [WriteTool] research notes: #{research_notes.length} chars"
    result = Phronomy::Agent.open_scope { |agents| agents.create(WriterAgent).invoke_async(prompt) }[:output]
    Example05Validation.require_text!(result, "Writer returned no final-answer text")
    $accumulated_tool_chars = ($accumulated_tool_chars || 0) + result.length
    puts "  [WriteTool] done: #{result.length} chars in #{(Time.now - t0).round(1)}s (total tool chars: #{$accumulated_tool_chars})"
    result
  end
end

class OrchestratorAgent < Phronomy::Agent::Base
  agent_definition id: "example-05-orchestrator-agent", version: 3

  model LLMConfig::MODEL
  provider LLMConfig::PROVIDER
  before_llm_input Example05Budget.method(:patch)
  context_policy Example05InputPolicy.new
  tools(
    ResearchTool => nil,
    WriteTool => nil
  )
  instructions "You are an orchestrator responsible for producing a concise technical blog post. " \
               "Use the research tool to gather bullet-point notes, then the write tool to produce the article. " \
               "Copy the complete research result verbatim into the write tool research_notes argument. " \
               "Do not invent, summarize, or replace the research notes. " \
               "The writer has been instructed to produce a concise article (250-350 words). " \
               "After the write tool returns, briefly report that the article is ready. " \
               "The application publishes the writer's result directly; do not repeat or rewrite the article."
end
