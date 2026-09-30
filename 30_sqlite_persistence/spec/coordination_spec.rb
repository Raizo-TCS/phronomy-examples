# frozen_string_literal: true

require "spec_helper"
require_relative "../../shared/persistence_coordination_contract"

RSpec.describe "SQLite durable coordination" do
  let(:persistence) { build_sqlite_persistence.first }
  it_behaves_like "a SQL coordination backend"
end

require_relative "../../shared/reserved_child_admission_contract"

RSpec.describe "SQLite atomic child acceptance" do
  let(:persistence) { build_sqlite_persistence.first }
  it_behaves_like "atomic reserved child admission"
end
