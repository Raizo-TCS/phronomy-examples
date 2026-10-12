# frozen_string_literal: true

require "spec_helper"
require_relative "../../shared/agent_scope_contract"

RSpec.describe "Agent scope lifetimes through PostgreSQL" do
  let(:initial_storage) { build_postgresql_persistence }
  let(:reopened_storage) { build_postgresql_persistence }

  it_behaves_like "persisted Agent scope lifetimes"
end
