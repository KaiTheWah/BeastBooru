# frozen_string_literal: true

class CreateUserEvents < ActiveRecord::Migration[7.1]
  def change
    create_table(:user_events) do |t|
      t.references(:user, foreign_key: true, null: false)
      t.references(:user_session, foreign_key: true, null: false)
      t.integer(:category, null: false, index: true)
      t.inet(:ip_addr, null: false, index: true)
      t.string(:session_id, null: false, index: true)
      t.string(:user_agent, index: true)
      t.jsonb(:metadata, default: {}, null: false)
      t.timestamps
    end
  end
end
