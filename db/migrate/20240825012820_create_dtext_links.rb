# frozen_string_literal: true

class CreateDtextLinks < ActiveRecord::Migration[7.1]
  def change
    create_table(:dtext_links) do |t|
      t.references(:model, polymorphic: true, null: false)
      t.integer(:link_type, null: false, index: true)
      t.string(:link_target, null: false, index: { opclass: "text_pattern_ops" })
      t.timestamps
    end
  end
end
