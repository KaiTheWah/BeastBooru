# frozen_string_literal: true

class CreatePostAppeals < ActiveRecord::Migration[7.1]
  def change
    create_table(:post_appeals) do |t|
      t.references(:post, foreign_key: true, null: false)
      t.references(:creator, foreign_key: { to_table: :users }, null: false)
      t.inet(:creator_ip_addr, null: false)
      t.string(:reason, null: false, default: "")
      t.integer(:status, null: false, default: 0)
      t.timestamps
    end
    add_column(:users, :post_appealed_count, :integer, default: 0)
  end
end
