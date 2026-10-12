# frozen_string_literal: true

require "spec_helper"
require_relative "../../shared/workflow_task_state_contract"

RSpec.describe "Workflow task states through PostgreSQL" do
  let(:initial_storage) { build_postgresql_persistence }
  let(:reopened_storage) { build_postgresql_persistence }

  it_behaves_like "persisted Workflow task states"
end
