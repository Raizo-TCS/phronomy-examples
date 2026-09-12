# frozen_string_literal: true

require "spec_helper"
require_relative "../../shared/persistence_coordination_contract"

RSpec.describe "PostgreSQL durable coordination" do
  let(:persistence) { build_postgresql_persistence.first }
  it_behaves_like "a SQL coordination backend"
end
