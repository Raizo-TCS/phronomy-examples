# frozen_string_literal: true

require "active_record"
require_relative "../lib/active_record_postgresql_persistence"

module PhronomyExamples
  module Persistence
    module PostgreSQLSchema
      TABLES = %i[
        phronomy_workflow_states
        phronomy_executions
        phronomy_journal_records
        phronomy_journal_heads
        phronomy_agents
        phronomy_contents
      ].freeze

      module_function

      def apply!(connection_pool)
        connection_pool.with_connection do |connection|
          assert_postgresql!(connection)
          create_contents(connection)
          create_agents(connection)
          create_journals(connection)
          create_executions(connection)
          create_workflow_states(connection)
        end
      end

      def reset!(connection_pool)
        connection_pool.with_connection do |connection|
          assert_postgresql!(connection)
          TABLES.each do |table|
            connection.drop_table(table, if_exists: true)
          end
        end
        apply!(connection_pool)
      end

      def assert_postgresql!(connection)
        return if connection.adapter_name == "PostgreSQL"

        raise Phronomy::Persistence::UnsupportedBackendError,
              "PostgreSQLSchema requires the ActiveRecord PostgreSQL adapter"
      end
      private_class_method :assert_postgresql!

      def create_contents(connection)
        unless connection.table_exists?(:phronomy_contents)
          connection.create_table(:phronomy_contents, id: false) do |table|
            table.string :content_id, null: false
            table.binary :bytes, null: false
            table.integer :canonicalization_version, null: false
          end
        end

        add_unique_index(
          connection,
          :phronomy_contents,
          :content_id,
          "idx_phronomy_contents_content_id"
        )
      end
      private_class_method :create_contents

      def create_agents(connection)
        unless connection.table_exists?(:phronomy_agents)
          connection.create_table(:phronomy_agents, id: false) do |table|
            table.string :agent_id, null: false
            table.integer :revision, null: false
            table.text :root_json, null: false
          end
        end

        add_unique_index(
          connection,
          :phronomy_agents,
          :agent_id,
          "idx_phronomy_agents_agent_id"
        )
      end
      private_class_method :create_agents

      def create_journals(connection)
        unless connection.table_exists?(:phronomy_journal_heads)
          connection.create_table(:phronomy_journal_heads, id: false) do |table|
            table.string :agent_id, null: false
            table.integer :position, null: false
          end
        end

        add_unique_index(
          connection,
          :phronomy_journal_heads,
          :agent_id,
          "idx_phronomy_journal_heads_agent_id"
        )

        unless connection.table_exists?(:phronomy_journal_records)
          connection.create_table(:phronomy_journal_records, id: false) do |table|
            table.string :agent_id, null: false
            table.integer :sequence, null: false
            table.string :record_id, null: false
            table.text :record_json, null: false
          end
        end

        add_unique_index(
          connection,
          :phronomy_journal_records,
          %i[agent_id sequence],
          "idx_phronomy_journal_records_sequence"
        )
        add_unique_index(
          connection,
          :phronomy_journal_records,
          %i[agent_id record_id],
          "idx_phronomy_journal_records_record_id"
        )
      end
      private_class_method :create_journals

      def create_executions(connection)
        unless connection.table_exists?(:phronomy_executions)
          connection.create_table(:phronomy_executions, id: false) do |table|
            table.string :execution_id, null: false
            table.string :agent_id, null: false
            table.integer :revision, null: false
            table.string :status, null: false
            table.boolean :active, null: false
            table.text :execution_json, null: false
          end
        end

        add_unique_index(
          connection,
          :phronomy_executions,
          :execution_id,
          "idx_phronomy_executions_execution_id"
        )

        index_name = "idx_phronomy_executions_one_active"
        return if connection.index_exists?(:phronomy_executions, :agent_id, name: index_name)

        connection.add_index(
          :phronomy_executions,
          :agent_id,
          unique: true,
          where: "active IS TRUE",
          name: index_name
        )
      end
      private_class_method :create_executions

      def create_workflow_states(connection)
        unless connection.table_exists?(:phronomy_workflow_states)
          connection.create_table(:phronomy_workflow_states, id: false) do |table|
            table.string :thread_id, null: false
            table.integer :revision, null: false
            table.text :snapshot_json, null: false
          end
        end

        add_unique_index(
          connection,
          :phronomy_workflow_states,
          :thread_id,
          "idx_phronomy_workflow_states_thread_id"
        )
      end
      private_class_method :create_workflow_states

      def add_unique_index(connection, table, columns, name)
        return if connection.index_exists?(table, columns, name: name)

        connection.add_index(table, columns, unique: true, name: name)
      end
      private_class_method :add_unique_index
    end
  end
end
