# frozen_string_literal: true

require "phronomy/active_record"

module PhronomyStore
  class << self
    attr_reader :persistence
  end

  # Rails owns the pool and explicitly runs the application's migrations.
  @persistence = PhronomyActiveRecord.build(
    connection_pool: ActiveRecord::Base.connection_pool, dialect: :sqlite
  ).agent
end
