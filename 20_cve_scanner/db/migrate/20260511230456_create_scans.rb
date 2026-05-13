class CreateScans < ActiveRecord::Migration[8.1]
  def change
    create_table :scans do |t|
      t.text :cve_ids
      t.string :status
      t.text :state_json
      t.text :result_json

      t.timestamps
    end
  end
end
