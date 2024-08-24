# frozen_string_literal: true

class AddWikiProtectionLevel < ActiveRecord::Migration[7.1]
  def change
    add_column(:wiki_pages, :protection_level, :integer)
    add_column(:wiki_page_versions, :protection_level, :integer)
    remove_column(:wiki_pages, :is_locked, :boolean, default: false, null: false)
    remove_column(:wiki_page_versions, :is_locked, :boolean, null: false)
  end
end
