# frozen_string_literal: true

require "phronomy"
require "phronomy/active_record"
require "phronomy/active_record/schema_v1/sqlite"

module WorkerApproval
  class Record < ActiveRecord::Base
    self.abstract_class = true
  end

  def self.store(path, install: false)
    Record.establish_connection(adapter: "sqlite3", database: path, pool: 8, timeout: 5_000)
    pool = Record.connection_pool
    PhronomyActiveRecord::Persistence::SQLiteSchema.apply!(pool) if install
    PhronomyActiveRecord.build(connection_pool: pool, dialect: :sqlite).agent
  end

  class ApplyRequest < Phronomy::Tool::Base
    tool_name "apply_request"
    description "Apply the approved change."
    requires_approval true

    def execute
      File.open(ENV.fetch("APPROVED_EFFECT_LOG"), "a") { |log| log.puts(Process.pid) }
      "applied"
    end
  end

  class Conversation < Phronomy::Agent::Base
    agent_definition id: "worker-approval", version: 1
    model "gpt-4o-mini"
    provider :openai
    tools ApplyRequest => nil
  end
end
