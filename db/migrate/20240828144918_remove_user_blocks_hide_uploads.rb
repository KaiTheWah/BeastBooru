class RemoveUserBlocksHideUploads < ActiveRecord::Migration[7.1]
  def change
    remove_column(:user_blocks, :hide_uploads, :boolean, default: false, null: false)
  end
end
