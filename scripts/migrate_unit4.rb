# frozen_string_literal: true

# Run with either reference example's bundle and PHRONOMY_PATH set to unit 4.
# SOURCE_DATABASE_URL/DESTINATION_DATABASE_URL must refer to distinct offline DBs.
require "bundler/setup"
require "active_record"
require "phronomy"
require "json"
require_relative "../shared/unit4_snapshot"
require_relative "../30_sqlite_persistence/db/schema"
require_relative "../31_postgresql_persistence/db/schema"

mode, input, output = ARGV
abort "usage: migrate_unit4.rb export|convert|import|verify INPUT OUTPUT --quiescent" unless ARGV.include?("--quiescent")

class MigrationSource < ActiveRecord::Base
  self.abstract_class = true
end

class MigrationDestination < ActiveRecord::Base
  self.abstract_class = true
end

class MigrationVerification < ActiveRecord::Base
  self.abstract_class = true
end

case mode
when "export"
  MigrationSource.establish_connection(ENV.fetch("SOURCE_DATABASE_URL"))
  snapshot = PhronomyExamples::Persistence::Unit4Snapshot.export(MigrationSource.connection_pool, revision: "r8-unit3")
  File.write(input, JSON.pretty_generate(snapshot), mode: "wx")
when "convert"
  snapshot = Phronomy::PersistenceComposition::Unit4Migration.convert(JSON.parse(File.read(input)), quiescent: true)
  File.write(output, JSON.pretty_generate(snapshot), mode: "wx")
when "import", "verify"
  url = ENV.fetch("DESTINATION_DATABASE_URL")
  abort "source and destination must differ" if ENV["SOURCE_DATABASE_URL"] == url
  snapshot = JSON.parse(File.read(input))
  MigrationDestination.establish_connection(url)
  pool = MigrationDestination.connection_pool
  if mode == "import"
    adapter = pool.with_connection(&:adapter_name)
    schema, driver = case adapter
    when "SQLite" then [PhronomyExamples::Persistence::SQLiteSchema, PhronomyExamples::Persistence::ActiveRecordSQLite]
    when "PostgreSQL" then [PhronomyExamples::Persistence::PostgreSQLSchema, PhronomyExamples::Persistence::ActiveRecordPostgreSQL]
    else abort "unsupported migration adapter: #{adapter}"
    end
    schema.apply!(pool)
    PhronomyExamples::Persistence::Unit4Snapshot.import(snapshot, backend: driver.new(connection_pool: pool), connection_pool: pool)
  end
  MigrationVerification.establish_connection(url)
  PhronomyExamples::Persistence::Unit4Snapshot.verify(snapshot, connection_pool: MigrationVerification.connection_pool)
else
  abort "unknown migration mode"
end
puts "#{mode}: succeeded; database cutover remains explicit"
