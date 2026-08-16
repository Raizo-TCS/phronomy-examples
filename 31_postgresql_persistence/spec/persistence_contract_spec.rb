# frozen_string_literal: true

require "spec_helper"
require "phronomy/testing/persistence_contract"

RSpec.describe PhronomyExamples::Persistence::ActiveRecordPostgreSQL do
  let(:persistence) { build_postgresql_persistence.first }

  it_behaves_like "a persistence content store"
  it_behaves_like "an Agent repository"
  it_behaves_like "a Journal repository"
  it_behaves_like "an Execution repository"
  it_behaves_like "a workflow state repository"
  it_behaves_like "a Persistence backend"
end
