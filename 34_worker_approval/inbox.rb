# frozen_string_literal: true

require "json"
require "securerandom"
require_relative "database"

class Inbox
  class ConflictingRequest < StandardError; end
  class StaleAcknowledgement < StandardError; end

  def initialize(database)
    @database = database
  end

  def setup
    Database.open(@database) do |db|
      db.execute_batch(<<~SQL)
        PRAGMA journal_mode=WAL;
        CREATE TABLE inbox(seq INTEGER PRIMARY KEY, request_id TEXT UNIQUE NOT NULL,
          target TEXT NOT NULL, body TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'queued',
          owner TEXT, result TEXT);
        CREATE UNIQUE INDEX one_owner_per_target ON inbox(target) WHERE status='running';
      SQL
    end
  end

  def submit(id, target, body)
    Database.open(@database) { |db| insert_or_lookup(db, id, target, body) }
  end

  def claim
    Database.open(@database) do |db|
      row = nil
      db.transaction(:immediate) do
        row = db.get_first_row(<<~SQL)
          SELECT q.* FROM inbox q WHERE q.status='queued'
            AND NOT EXISTS (SELECT 1 FROM inbox r WHERE r.target=q.target AND r.status='running')
          ORDER BY q.seq LIMIT 1
        SQL
        if row
          row["owner"] = SecureRandom.uuid
          db.execute("UPDATE inbox SET status='running',owner=? WHERE seq=?", row.values_at("owner", "seq"))
        end
      end
      row
    end
  end

  def finish(job, result)
    Database.open(@database) { |db| finish_claim(db, job, status: "done", result: result) }
  end

  def lookup(id)
    Database.open(@database) { |db| db.get_first_row("SELECT * FROM inbox WHERE request_id=?", [id]) }
  end

  protected

  def finish_claim(db, job, status:, result:)
    db.execute("UPDATE inbox SET status=?,result=? WHERE seq=? AND owner=? AND status='running'",
      [status, JSON.generate(result), job.fetch("seq"), job.fetch("owner")])
    raise StaleAcknowledgement, "stale acknowledgement" unless db.changes == 1
  end

  def insert_or_lookup(db, id, target, body)
    db.execute("INSERT INTO inbox(request_id,target,body) VALUES(?,?,?) ON CONFLICT(request_id) DO NOTHING",
      [id, target, JSON.generate(body)])
    row = db.get_first_row("SELECT * FROM inbox WHERE request_id=?", [id])
    unless row.fetch("target") == target && JSON.parse(row.fetch("body")) == body
      raise ConflictingRequest, "request ID reused with different contents"
    end
    row
  end
end
