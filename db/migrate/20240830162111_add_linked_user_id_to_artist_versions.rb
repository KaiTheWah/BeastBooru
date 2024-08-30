# frozen_string_literal: true

class AddLinkedUserIdToArtistVersions < ActiveRecord::Migration[7.1]
  def change
    add_reference(:artist_versions, :linked_user, foreign_key: { to_table: :users, foreign_key: true })
  end
end
