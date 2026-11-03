# frozen_string_literal: true

require "sqlite3"

module Database
  def self.open(path)
    db = SQLite3::Database.new(path)
    db.results_as_hash = true
    db.busy_timeout(15_000)
    db.execute("PRAGMA foreign_keys=ON")
    yield db
  ensure
    db&.close
  end
end
