# frozen_string_literal: true

class AddMFASecretToUsers < ActiveRecord::Migration[7.1]
  def change
    add_column(:users, :mfa_secret, :string)
    add_column(:users, :mfa_last_used_at, :datetime)
    add_column(:users, :backup_codes, :string, array: true)
  end
end
