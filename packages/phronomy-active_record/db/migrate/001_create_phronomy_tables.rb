# frozen_string_literal: true

require "phronomy/active_record/schema_v1"

class CreatePhronomyTables < ActiveRecord::Migration[7.1]
  def up
    PhronomyActiveRecord::SchemaV1.install!(connection: connection)
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "Archive Agent, Team and Workflow data before removing persistence tables"
  end
end
