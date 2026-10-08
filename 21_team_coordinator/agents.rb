# frozen_string_literal: true

require_relative "../shared/llm_config"
require_relative "../shared/output_validator"
require "phronomy"

# ---------------------------------------------------------------------------
# Worker: writes one blog section per invocation, accumulating style context
# ---------------------------------------------------------------------------
class BlogSectionWriter < Phronomy::Agent::Base
  agent_definition id: "example-21-blog-section-writer", version: 1

  model        LLMConfig::MODEL
  provider     LLMConfig::PROVIDER
  instructions <<~INST
    You are a concise technical blog writer for Ruby developers.
    Write the requested blog section clearly and engagingly.
    Keep each section under 150 words.
    When you have written previous sections, maintain a consistent tone and
    refer back to earlier content where appropriate.
  INST
end

# ---------------------------------------------------------------------------
# Team: coordinator decomposes the topic, two workers share the writing load
# ---------------------------------------------------------------------------
class BlogWritingTeam < Phronomy::MultiAgent::TeamCoordinator
  team_definition id: "example-21-blog-writing-team", version: 1

  coordinator_model        LLMConfig::MODEL
  coordinator_provider     LLMConfig::PROVIDER
  coordinator_instructions <<~INST
    You are a blog editor. Your job is to plan the structure of a technical
    blog post on the given topic.
    Break the post into 4-5 sections (e.g. Introduction, Core Concepts,
    Code Example, Practical Tips, Conclusion).
    For each section, call enqueue_task with a description like:
      "Write the [Section Name] section. Cover: <key points>"
    Enqueue every section before calling finalize exactly once.
    After finalize, reply with a short confirmation without any more tool calls.
  INST

  pool size: 2, agent: BlogSectionWriter

  aggregate do |assignments|
    {
      sections: assignments.map { |a|
        {worker: a[:worker], description: a[:task][:description], content: a[:result]}
      }
    }
  end

  def self.generate(topic, &listener)
    OutputValidator.validate(
      "team coordinator produces 4+ blog sections",
      check: ->(result) {
        result.fetch("sections").size >= 4 &&
          result.fetch("sections").all? { |section| section.fetch("content").to_s.length >= 50 }
      }
    ) { generate_once(topic, &listener) }
  end

  def self.generate_once(topic, &listener)
    team = new
    team.stream(topic, &listener)
  rescue Phronomy::ExecutionRehydrationRequiredError
    raise
  rescue Phronomy::Error
    raise unless team

    execution = team.executions.first
    outcome = team.result(execution.team_execution_id) if execution
    unless outcome && outcome[:status] == "failed" &&
        outcome.dig(:error, "class") == "Phronomy::ConfigurationError" &&
        outcome.dig(:error, "message") == "Cannot enqueue after finalize"
      raise
    end

    warn "[planning] A finalized plan rejected a later task; generating a new plan."
    {"sections" => []}
  end
  private_class_method :generate_once
end
