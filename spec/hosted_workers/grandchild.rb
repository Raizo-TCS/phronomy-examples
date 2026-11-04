# frozen_string_literal: true

require "open3"
require "rbconfig"
require "tmpdir"
require "webmock"
require_relative "../../34_worker_approval/conversation"
require_relative "../support/chat_stub"

module GrandchildAudit
  class Stamp < Phronomy::Tool::Base
    tool_name "stamp"
    description "Record one test-only side effect."

    def execute
      File.open(ENV.fetch("AUDIT_EFFECTS"), "a") { |file| file.puts(Process.pid) }
      "stamped"
    end
  end

  class Leaf < Phronomy::Agent::Base
    agent_definition id: "matrix-leaf", version: 1
    model "gpt-4o-mini"
    provider :openai
    tools Stamp => nil
  end

  class Middle < Phronomy::MultiAgent::Orchestrator
    agent_definition id: "matrix-middle", version: 1
    model "gpt-4o-mini"
    provider :openai
    subagent :leaf, Leaf
  end

  class Root < Phronomy::MultiAgent::Orchestrator
    agent_definition id: "matrix-root", version: 1
    model "gpt-4o-mini"
    provider :openai
    subagent :middle, Middle
  end

  def self.provider
    WebMock.enable!
    WebMock.disable_net_connect!
    RubyLLM.configure do |config|
      config.openai_protocol = :chat_completions
      config.openai_api_base = "https://example.test/v1"
      config.openai_api_key = "fixture"
    end
    ExampleChatStub.new do |body, _|
      last = body.fetch("messages").last
      tools = body.fetch("tools").map { |tool| tool.fetch("function").fetch("name") }
      if last.fetch("role") == "tool"
        "imported(#{last.fetch("content")})"
      elsif tools.include?("dispatch_to_middle")
        ExampleChatStub.tool("dispatch_to_middle", {input: last.fetch("content")})
      elsif tools.include?("dispatch_to_leaf")
        ExampleChatStub.tool("dispatch_to_leaf", {input: last.fetch("content")})
      else
        ExampleChatStub.tool("stamp")
      end
    end
  end

  # Read native slot references solely to identify the child executions in this test.
  def self.snapshot(stores)
    identities = [["root", "root-execution"]]
    2.times do
      agent_id, execution_id = identities.last
      extension = stores.agent.execution_extension(agent_id: agent_id, execution_id: execution_id, binding_key: "phronomy.subagent")
      slots = stores.multi_agent.contents.fetch_json(extension.state_ref).fetch("children")
      raise "Expected one direct child" unless slots.size == 1
      identities << slots.first.values_at("agent_id", "execution_id")
    end
    identities.map do |agent_id, execution_id|
      execution = stores.agent.observe_execution(agent_id: agent_id, execution_id: execution_id)
      [agent_id, execution_id, execution.status.to_s]
    end
  end

  def self.worker(path, role)
    stores = WorkerApproval.stores(path, install: role == "origin")
    Phronomy.configure { |config| config.multi_agent_store = stores.multi_agent }
    fixture = provider
    if role == "origin"
      root = Root.create(agent_id: "root", persistence: stores.agent, coordination_store: stores.multi_agent)
      reservation = Phronomy::Agent::ReservedExecution.new(agent_id: root.agent_id, execution_id: "root-execution")
      answer = root.start_hosted(reservation: reservation, input: "stamp once").wait_result(timeout: 15)
      raise "Root did not import its descendants' outputs" unless answer.fetch(:output) == "imported(imported(imported(stamped)))"
    end
    puts JSON.generate(pid: Process.pid, chain: snapshot(stores), model_calls: fixture.calls.size)
  end

  def self.call_worker(path, effects, role)
    output, errors, status = Open3.capture3({"AUDIT_EFFECTS" => effects}, RbConfig.ruby, __FILE__, "worker", path, role)
    raise "Worker #{role} failed (#{status.exitstatus}): #{errors}\n#{output}" unless status.success?
    JSON.parse(output)
  end

  def self.run
    Dir.mktmpdir("grandchild-") do |dir|
      path = File.join(dir, "state.sqlite3")
      effects = File.join(dir, "effects.log")
      origin = call_worker(path, effects, "origin")
      reader = call_worker(path, effects, "reader")
      raise "Same worker PID" if origin.fetch("pid") == reader.fetch("pid")
      raise "Reader invoked the model" unless reader.fetch("model_calls").zero?
      raise "Reader found a different chain" unless origin.fetch("chain") == reader.fetch("chain")
      raise "Incomplete chain" unless reader.fetch("chain").map(&:last) == %w[completed completed completed]
      raise "Lost or duplicate Tool effect" unless File.readlines(effects, chomp: true) == [origin.fetch("pid").to_s]
      puts "plain: parent, child and grandchild completed; one Tool effect; independent reader verified the stored chain"
    end
  end
end

if ARGV.first == "worker"
  GrandchildAudit.worker(*ARGV.drop(1))
else
  abort "Usage: ruby grandchild.rb [plain]" unless ARGV.empty? || ARGV == ["plain"]
  GrandchildAudit.run
end
