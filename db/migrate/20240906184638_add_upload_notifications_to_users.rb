# frozen_string_literal: true

class AddUploadNotificationsToUsers < ActiveRecord::Migration[7.1]
  def change
    add_column(:users, :upload_notifications, :string, array: true, default: [], null: false)
  end
end
