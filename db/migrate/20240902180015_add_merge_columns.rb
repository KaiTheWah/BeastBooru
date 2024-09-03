# frozen_string_literal: true

class AddMergeColumns < ActiveRecord::Migration[7.1]
  def change
    # Foreign key intentionally omitted so we don't interfere with destroying
    add_reference(:forum_topics, :merge_target, foreign_key: false)
    add_column(:forum_topics, :merged_at, :datetime)
    add_reference(:forum_posts, :original_topic, foreign_key: false)
    add_column(:forum_posts, :merged_at, :datetime)
  end
end
