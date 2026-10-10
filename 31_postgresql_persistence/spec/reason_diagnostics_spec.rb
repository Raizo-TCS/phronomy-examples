# frozen_string_literal: true

require "spec_helper"
require_relative "../../shared/reason_diagnostics_contract"

RSpec.describe "Reason diagnostics through PostgreSQL" do
  let(:initial_storage) { build_postgresql_persistence }
  let(:reopened_storage) { build_postgresql_persistence }

  it_behaves_like "persisted reason diagnostics"
end
