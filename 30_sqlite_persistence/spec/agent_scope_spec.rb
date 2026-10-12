# frozen_string_literal: true

require "spec_helper"
require_relative "../../shared/agent_scope_contract"

RSpec.describe "Agent scope lifetimes through SQLite" do
  let(:initial_storage) { build_sqlite_persistence }
  let(:reopened_storage) { build_sqlite_persistence(database_path: initial_storage.fetch(2)) }

  it_behaves_like "persisted Agent scope lifetimes"
end
