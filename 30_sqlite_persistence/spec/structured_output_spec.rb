# frozen_string_literal: true
require_relative "spec_helper"
require_relative "../../shared/structured_output_contract"
RSpec.describe "Structured output through SQLite" do
  let(:initial_storage) { build_sqlite_persistence }
  let(:reopened_storage) { build_sqlite_persistence(database_path: initial_storage.fetch(2)) }
  it_behaves_like "persisted structured output"
end
