# frozen_string_literal: true

class MajorityVoter < Phronomy::Agent::Base
  agent_definition id: "example-32-majority-voter", version: 1
  model LLMConfig::MODEL
  provider LLMConfig::PROVIDER
  instructions "Consider the question independently. Return only YES or NO."
end

class MajorityEvaluator < Phronomy::Agent::Base
  agent_definition id: "example-32-majority-evaluator", version: 1
  model LLMConfig::MODEL
  provider LLMConfig::PROVIDER
  instructions "Evaluate the proposed answer against the question. Return only YES or NO."
end
