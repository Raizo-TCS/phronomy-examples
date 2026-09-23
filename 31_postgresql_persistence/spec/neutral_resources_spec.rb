# frozen_string_literal: true

require "spec_helper"
require_relative "../../shared/storage_resource_contract"

RSpec.describe "Neutral postgresql resources" do
  def build_persistence = build_postgresql_persistence.first
  let(:storage_dialect) { :postgresql }
  include_examples "a neutral SQL resource driver"
end
