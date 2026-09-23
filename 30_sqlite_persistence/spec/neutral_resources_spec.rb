# frozen_string_literal: true

require "spec_helper"
require_relative "../../shared/storage_resource_contract"

RSpec.describe "Neutral sqlite resources" do
  def build_persistence = build_sqlite_persistence.first
  let(:storage_dialect) { :sqlite }
  include_examples "a neutral SQL resource driver"
end
