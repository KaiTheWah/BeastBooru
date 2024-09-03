# frozen_string_literal: true

class AddExtraDataToEditHistories < ActiveRecord::Migration[7.1]
  def change
    add_column(:edit_histories, :extra_data, :jsonb, null: false, default: {})
  end
end
