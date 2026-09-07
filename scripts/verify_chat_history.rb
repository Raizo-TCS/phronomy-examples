# frozen_string_literal: true

# Run inside example 09 or 15:
#   RAILS_ENV=test bundle exec rails runner ../scripts/verify_chat_history.rb
# Uses imported conversation records and real HTTP/controller/view processing;
# no LLM requests are needed. All created Agents belong to this test session.
require "cgi"
require "action_dispatch/testing/integration"

abort "Run this verification with RAILS_ENV=test" unless Rails.env.test?
agent_class = case Rails.root.basename.to_s
when "09_rails_chat" then ChatAgent
when "15_rails_secure_chat" then SecureChatAgent
else abort "This verification targets examples 09 and 15"
end

agent_id = nil
begin
  browser = ActionDispatch::Integration::Session.new(Rails.application)
  browser.get("/up")
  raise "Health endpoint failed: #{browser.response.status}" unless browser.response.status == 200
  browser.post("/conversations")
  raise "Conversation creation failed: #{browser.response.status}" unless browser.response.status == 302
  agent_id = browser.request.session.fetch(:agent_id)
  agent_class.get(agent_id).purge!

  inputs = ["123", "null", "false", '{"content":"preserved user JSON"}']
  context = inputs.flat_map do |input|
    [{role: :user, content: input}, {role: :assistant, content: "Reply to #{input}"}]
  end
  agent_class.create(agent_id: agent_id, persistence: PhronomyStore.persistence, context: context)
  # Exercise loading the saved owner instead of relying on a live Agent cache.
  Phronomy.reset_runtime!
  browser.get("/")
  raise "History rendering failed: #{browser.response.status}" unless browser.response.status == 200
  text = CGI.unescapeHTML(browser.response.body)
  inputs.each { |input| raise "History lost literal text: #{input}" unless text.include?(input) }
  puts "Chat history passed: health, creation, saved-owner load, numeric/null/boolean/JSON text."
ensure
  if agent_id
    agent_class.load(agent_id, persistence: PhronomyStore.persistence).purge!
  end
  Phronomy.reset_runtime!
end
