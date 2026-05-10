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

ActiveRecord::Schema[8.1].define(version: 2026_05_10_031831) do
  create_table "phronomy_checkpoints", force: :cascade do |t|
    t.string "completed_node"
    t.datetime "created_at", null: false
    t.string "graph_id"
    t.string "interrupted_at"
    t.text "state_json", null: false
    t.integer "step", default: 0, null: false
    t.string "thread_id", null: false
    t.datetime "updated_at", null: false
    t.index ["thread_id", "created_at"], name: "index_phronomy_checkpoints_on_thread_id_and_created_at"
    t.index ["thread_id"], name: "index_phronomy_checkpoints_on_thread_id", unique: true
  end

  create_table "phronomy_messages", force: :cascade do |t|
    t.text "content", null: false
    t.datetime "created_at", null: false
    t.string "model_id"
    t.string "role", null: false
    t.string "thread_id", null: false
    t.text "tool_calls_json"
    t.datetime "updated_at", null: false
    t.index ["thread_id", "created_at"], name: "index_phronomy_messages_on_thread_id_and_created_at"
    t.index ["thread_id"], name: "index_phronomy_messages_on_thread_id"
  end
end
