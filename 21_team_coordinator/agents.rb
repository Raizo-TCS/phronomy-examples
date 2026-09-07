# frozen_string_literal: true

require_relative "../shared/llm_config"
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
    Call finalize when all sections are enqueued.
  INST

  pool size: 2, agent: BlogSectionWriter

  aggregate do |assignments|
    {
      sections: assignments.map { |a|
        {worker: a[:worker], description: a[:task][:description], content: a[:result]}
      }
    }
  end
end
