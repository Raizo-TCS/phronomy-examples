# frozen_string_literal: true
require_relative "spec_helper"
require_relative "../../shared/structured_output_contract"
RSpec.describe "Structured output through PostgreSQL" do
  let(:initial_storage) { build_postgresql_persistence }
  let(:reopened_storage) { build_postgresql_persistence }
  it_behaves_like "persisted structured output"
end
