# frozen_string_literal: true

class AddUniqueIndexes < ActiveRecord::Migration[7.1]
  def change
    add_index(:api_keys, %i[name user_id], unique: true)
    add_index(:artist_urls, %i[artist_id url], unique: true)
    remove_index(:avoid_postings, :artist_id)
    add_index(:avoid_postings, :artist_id, unique: true)
    add_index(:dtext_links, %i[link_target model_type model_id], unique: true)
    add_index(:email_blacklists, "lower(domain)", unique: true)
    add_index(:forum_categories, "lower(name)", unique: true)
    add_index(:post_deletion_reasons, "lower(reason)", unique: true)
    add_index(:post_deletion_reasons, "lower(title)", unique: true, where: "title != ''")
    add_index(:post_deletion_reasons, "lower(prompt)", unique: true, where: "title != ''")
    add_index(:post_deletion_reasons, :order, unique: true)
    add_index(:post_disapprovals, %i[post_id user_id], unique: true)
    add_index(:post_replacement_rejection_reasons, "lower(reason)", unique: true)
    add_index(:post_replacement_rejection_reasons, :order, unique: true)
    add_index(:quick_rules, :order, unique: true)
    add_index(:rules, "lower(name)", unique: true)
    add_index(:rules, %i[order category_id], unique: true)
    add_index(:rule_categories, :order, unique: true)
    add_index(:rule_categories, "lower(name)", unique: true)
    add_index(:upload_whitelists, :pattern, unique: true)
    add_index(:user_blocks, %i[target_id user_id], unique: true)
  end
end
