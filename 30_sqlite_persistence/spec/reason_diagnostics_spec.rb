# frozen_string_literal: true

require "spec_helper"
require_relative "../../shared/reason_diagnostics_contract"

RSpec.describe "Reason diagnostics through SQLite" do
  let(:initial_storage) { build_sqlite_persistence }
  let(:reopened_storage) { build_sqlite_persistence(database_path: initial_storage.fetch(2)) }

  it_behaves_like "persisted reason diagnostics"
end
