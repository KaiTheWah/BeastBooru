# frozen_string_literal: true

class AddMergedFromToWikiPageVersions < ActiveRecord::Migration[7.1]
  def change
    # Foreign key intentionally omitted so we don't interfere with destroying
    add_reference(:wiki_page_versions, :merged_from, foreign_key: false)
    add_column(:wiki_page_versions, :merged_from_title, :string)
  end
end
