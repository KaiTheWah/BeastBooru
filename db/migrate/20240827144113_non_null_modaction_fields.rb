# frozen_string_literal: true

class NonNullModactionFields < ActiveRecord::Migration[7.1]
  def change
    change_column_null(:mod_actions, :creator_id, false)
    change_column_null(:mod_actions, :action, false)
    change_column_null(:mod_actions, :values, false, {})
    change_column_default(:mod_actions, :values, from: nil, to: {})
  end
end
