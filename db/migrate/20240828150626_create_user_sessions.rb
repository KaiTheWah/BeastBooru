# frozen_string_literal: true

class CreateUserSessions < ActiveRecord::Migration[7.1]
  def change
    create_table(:user_sessions) do |t|
      t.inet(:ip_addr, null: false, index: true)
      t.string(:session_id, null: false, index: true)
      t.string(:user_agent)
      t.timestamps
    end
  end
end
