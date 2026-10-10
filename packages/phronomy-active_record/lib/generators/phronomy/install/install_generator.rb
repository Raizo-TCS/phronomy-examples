# frozen_string_literal: true

require "rails/generators"
require "rails/generators/migration"
require "rails/generators/active_record"

module Phronomy
  module Generators
    class InstallGenerator < Rails::Generators::Base
      include Rails::Generators::Migration
      source_root File.expand_path("../../../../db/migrate", __dir__)
      desc "Copy the explicit Phronomy v1 schema migration (does not run DDL)"

      def self.next_migration_number(dirname)
        ActiveRecord::Generators::Base.next_migration_number(dirname)
      end

      def copy_migration
        migration_template "001_create_phronomy_tables.rb", "db/migrate/create_phronomy_tables.rb"
      end
    end
  end
end
