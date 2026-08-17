# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_08_16_180000) do
  create_table "phronomy_agents", id: false, force: :cascade do |t|
    t.string "agent_id", null: false
    t.integer "revision", null: false
    t.text "root_json", null: false
    t.index ["agent_id"], name: "idx_phronomy_agents_agent_id", unique: true
  end

  create_table "phronomy_contents", id: false, force: :cascade do |t|
    t.binary "bytes", null: false
    t.integer "canonicalization_version", null: false
    t.string "content_id", null: false
    t.index ["content_id"], name: "idx_phronomy_contents_content_id", unique: true
  end

  create_table "phronomy_executions", id: false, force: :cascade do |t|
    t.boolean "active", null: false
    t.string "agent_id", null: false
    t.string "execution_id", null: false
    t.text "execution_json", null: false
    t.integer "revision", null: false
    t.string "status", null: false
    t.index ["agent_id"], name: "idx_phronomy_executions_one_active", unique: true, where: "active = 1"
    t.index ["execution_id"], name: "idx_phronomy_executions_execution_id", unique: true
  end

  create_table "phronomy_journal_heads", id: false, force: :cascade do |t|
    t.string "agent_id", null: false
    t.integer "position", null: false
    t.index ["agent_id"], name: "idx_phronomy_journal_heads_agent_id", unique: true
  end

  create_table "phronomy_journal_records", id: false, force: :cascade do |t|
    t.string "agent_id", null: false
    t.string "record_id", null: false
    t.text "record_json", null: false
    t.integer "sequence", null: false
    t.index ["agent_id", "record_id"], name: "idx_phronomy_journal_records_record_id", unique: true
    t.index ["agent_id", "sequence"], name: "idx_phronomy_journal_records_sequence", unique: true
  end

  create_table "phronomy_workflow_states", id: false, force: :cascade do |t|
    t.integer "revision", null: false
    t.text "snapshot_json", null: false
    t.string "thread_id", null: false
    t.index ["thread_id"], name: "idx_phronomy_workflow_states_thread_id", unique: true
  end
end
