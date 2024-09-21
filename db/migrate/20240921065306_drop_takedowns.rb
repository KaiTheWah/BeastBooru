# frozen_string_literal: true

class DropTakedowns < ActiveRecord::Migration[7.1]
  def change
    drop_table(:takedowns)
  end
end
