class DropUsersEmailVerificationKey < ActiveRecord::Migration[7.1]
  def change
    remove_column(:users, :email_verification_key, :string)
  end
end
