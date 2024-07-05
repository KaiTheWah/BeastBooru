# frozen_string_literal: true

class Post < ApplicationRecord
  class RevertError < StandardError; end
  class DeletionError < StandardError; end
  class TimeoutError < StandardError; end

  # Tags to copy when copying notes.
  NOTE_COPY_TAGS = %w[translated partially_translated translation_check translation_request].freeze
  ASPECT_RATIO_REGEX = /^\d+:\d+$/

  module Flags
    HAS_CROPPED              = 1 << 0
    HIDE_FROM_ANONYMOUS      = 1 << 1
    HIDE_FROM_SEARCH_ENGINES = 1 << 2

    def self.map
      constants.to_h { |name| [name.to_s.downcase, const_get(name)] }
    end

    def self.list
      map.keys.map(&:to_sym)
    end
  end

  include FemboyFans::HasBitFlags
  has_bit_flags(Flags.map)

  before_validation :initialize_uploader, on: :create
  before_validation :merge_old_changes
  before_validation :apply_source_diff
  before_validation :apply_tag_diff, if: :should_process_tags?
  before_validation :normalize_tags, if: :should_process_tags?
  before_validation :tag_count_not_insane, if: :should_process_tags?
  before_validation :strip_source
  before_validation :fix_bg_color
  before_validation :blank_out_nonexistent_parents
  before_validation :remove_parent_loops
  validates :md5, uniqueness: { on: :create, message: ->(obj, _data) { "duplicate: #{Post.find_by(md5: obj.md5).id}" } }
  validates :rating, inclusion: { in: %w[s q e], message: "rating must be s, q, or e" }
  validates :bg_color, format: { with: /\A[A-Fa-f0-9]{6}\z/ }, allow_nil: true
  validates :description, length: { maximum: FemboyFans.config.post_descr_max_size }, if: :description_changed?
  validate :added_tags_are_valid, if: :should_process_tags?
  validate :removed_tags_are_valid, if: :should_process_tags?
  validate :has_artist_tag, if: :should_process_tags?
  validate :has_enough_tags, if: :should_process_tags?
  validate :post_is_not_its_own_parent
  validate :updater_can_change_rating
  validate :validate_thumbnail_frame
  before_save :update_tag_post_counts, if: :should_process_tags?
  before_save :set_tag_counts, if: :should_process_tags?
  before_save :update_qtags, if: :will_save_change_to_description?
  after_update :regenerate_image_samples, if: :saved_change_to_thumbnail_frame?
  after_save :create_post_events
  after_save :create_version
  after_save :update_parent_on_save
  after_save :apply_post_metatags
  after_commit :update_pool_artists
  after_commit :update_tag_followers, on: %i[create update]
  after_commit :delete_files, on: :destroy
  after_commit :remove_iqdb_async, on: :destroy
  after_commit :update_iqdb_async, on: :create
  after_commit :generate_video_samples, on: :create, if: :is_video?

  belongs_to :updater, class_name: "User", optional: true # this is handled in versions
  belongs_to :approver, class_name: "User", optional: true
  belongs_to :uploader, class_name: "User", counter_cache: "post_count"
  belongs_to :parent, class_name: "Post", optional: true
  has_one :upload, dependent: :destroy
  has_many :flags, class_name: "PostFlag", dependent: :destroy
  has_many :votes, class_name: "PostVote", dependent: :destroy
  has_many :notes, dependent: :destroy
  has_many :comments, -> { includes(:creator, :updater).order("comments.is_sticky DESC, comments.id") }, dependent: :destroy
  has_many :children, -> { order("posts.id") }, class_name: "Post", foreign_key: "parent_id"
  has_many :approvals, class_name: "PostApproval", dependent: :destroy
  has_many :disapprovals, class_name: "PostDisapproval", dependent: :destroy
  has_many :favorites
  has_many :replacements, class_name: "PostReplacement", dependent: :destroy

  attr_accessor :old_tag_string, :old_parent_id, :old_source, :old_rating,
                :do_not_version_changes, :tag_string_diff, :source_diff, :edit_reason, :tag_string_before_parse,
                :automated_edit

  has_many :versions, -> { order("post_versions.id ASC") }, class_name: "PostVersion", dependent: :destroy

  IMAGE_TYPES = %i[original large preview crop].freeze

  module Ratings
    SAFE = "s"
    QUESTIONABLE = "q"
    EXPLICIT = "e"

    def self.map
      constants.to_h { |x| [x.to_s.downcase, const_get(x)] }
    end
  end

  module PostFileMethods
    extend ActiveSupport::Concern

    module ClassMethods
      def delete_files(_post_id, md5, file_ext, force: false)
        if Post.exists?(md5: md5) && !force
          raise(DeletionError, "Files still in use; skipping deletion.")
        end

        FemboyFans.config.storage_manager.delete_post_files(md5, file_ext)
      end
    end

    def delete_files
      Post.delete_files(id, md5, file_ext, force: true)
    end

    def move_files_on_delete
      FemboyFans.config.storage_manager.move_file_delete(self)
    end

    def move_files_on_undelete
      FemboyFans.config.storage_manager.move_file_undelete(self)
    end

    def storage_manager
      FemboyFans.config.storage_manager
    end

    def file(type = :original)
      storage_manager.open_file(self, type)
    end

    def tagged_large_file_url
      storage_manager.file_url(self, :large)
    end

    def file_url
      storage_manager.file_url(self, :original)
    end

    def file_url_ext(ext)
      storage_manager.file_url_ext(self, :original, ext)
    end

    def scaled_url_ext(scale, ext)
      storage_manager.file_url_ext(self, :scaled, ext, scale: scale)
    end

    def large_file_url
      return file_url unless has_large?
      storage_manager.file_url(self, :large)
    end

    def preview_file_url
      storage_manager.file_url(self, :preview)
    end

    def reverse_image_url
      return large_file_url if has_large?
      preview_file_url
    end

    def file_path
      storage_manager.file_path(self, file_ext, :original, protected: is_deleted?)
    end

    def large_file_path
      storage_manager.file_path(self, file_ext, :large, protected: is_deleted?)
    end

    def preview_file_path
      storage_manager.file_path(self, file_ext, :preview, protected: is_deleted?)
    end

    def crop_file_url
      storage_manager.file_url(self, :crop)
    end

    def open_graph_video_url
      if image_height > 720 && has_sample_size?("720p")
        return scaled_url_ext("720p", "mp4")
      end
      file_url_ext("mp4")
    end

    def open_graph_image_url
      if is_image?
        if has_large?
          large_file_url
        else
          file_url
        end
      else
        preview_file_url
      end
    end

    def file_url_for(user)
      if user.default_image_size == "large" && image_width > FemboyFans.config.large_image_width
        large_file_url
      else
        file_url
      end
    end

    def file_url_ext_for(user, ext)
      if user.default_image_size == "large" && is_video? && has_sample_size?("720p")
        scaled_url_ext("720p", ext)
      else
        file_url_ext(ext)
      end
    end

    def display_class_for(user)
      if user.default_image_size == "original"
        ""
      else
        "fit-window"
      end
    end

    def has_preview?
      is_image? || is_video?
    end

    def has_dimensions?
      image_width.present? && image_height.present?
    end

    def preview_dimensions(max_px = FemboyFans.config.small_image_width)
      return [max_px, max_px] unless has_dimensions?
      height = width = max_px
      dimension_ratio = image_width.to_f / image_height
      if dimension_ratio > 1
        height = (width / dimension_ratio).to_i
      else
        width = (height * dimension_ratio).to_i
      end
      [height, width]
    end

    def has_sample_size?(scale)
      (generated_samples || []).include?(scale)
    end

    def scaled_sample_dimensions(box)
      ratio = [box[0] / image_width.to_f, box[1] / image_height.to_f].min
      width = [[image_width * ratio, 2].max.ceil, box[0]].min & ~1
      height = [[image_height * ratio, 2].max.ceil, box[1]].min & ~1
      [width, height]
    end

    def generate_video_samples(later: false)
      if later
        PostVideoConversionJob.set(wait: 1.minute).perform_later(id)
      else
        PostVideoConversionJob.perform_later(id)
      end
    end

    def regenerate_video_samples!
      # force code to assume no samples exist
      update_column(:generated_samples, nil)
      generate_video_samples(later: true)
    end

    def regenerate_image_samples(later: false)
      if later
        PostImageSampleJob.set(wait: 1.minute).perform_later(id)
      else
        PostImageSampleJob.perform_later(id)
      end
    end

    def regenerate_image_samples!
      file = self.file
      preview_file, crop_file, sample_file = ::PostThumbnailer.generate_resizes(file, image_height, image_width, is_video? ? :video : :image, frame: thumbnail_frame)
      storage_manager.store_file(sample_file, self, :large) if sample_file.present?
      storage_manager.store_file(preview_file, self, :preview) if preview_file.present?
      storage_manager.store_file(crop_file, self, :crop) if crop_file.present?
      update({ has_cropped: crop_file.present? })
    ensure
      file.close
    end
  end

  module ImageMethods
    def twitter_card_supported?
      image_width.to_i >= 280 && image_height.to_i >= 150
    end

    def has_large?
      return true if is_video?
      return false if is_gif?
      return false if has_tag?("animated_gif", "animated_png")
      is_image? && image_width.present? && image_width > FemboyFans.config.large_image_width
    end

    def has_large
      !!has_large?
    end

    def large_image_width
      if has_large?
        [FemboyFans.config.large_image_width, image_width].min
      else
        image_width
      end
    end

    def large_image_height
      ratio = FemboyFans.config.large_image_width.to_f / image_width.to_f
      if has_large? && ratio < 1
        (image_height * ratio).to_i
      else
        image_height
      end
    end

    def resize_percentage
      100 * large_image_width.to_f / image_width.to_f
    end
  end

  module ApprovalMethods
    def is_approvable?
      !is_status_locked? && is_pending? && approver.nil?
    end

    def unflag!
      flags.each(&:resolve!)
      update(is_flagged: false)
      PostEvent.add(id, CurrentUser.user, :flag_removed)
    end

    def approved_by?(user)
      approver == user || approvals.exists?(user: user)
    end

    def unapprove!
      PostEvent.add(id, CurrentUser.user, :unapproved)
      update(approver: nil, is_pending: true)
    end

    def is_unapprovable?(user)
      # Allow unapproval only by the approver
      return false if approver.present? && approver != user
      # Prevent unapproving self approvals by someone else
      return false if approver.nil? && uploader != user
      # Allow unapproval when the post is not pending anymore and is not at risk of auto deletion
      !is_pending? && !is_deleted? && created_at.after?(PostPruner::DELETION_WINDOW.days.ago)
    end

    def approve!(approver = CurrentUser.user)
      return unless self.approver.nil?

      if uploader == approver
        update(is_pending: false)
      else
        PostEvent.add(id, CurrentUser.user, :approved)
        approvals.create(user: approver)
        update(approver: approver, is_pending: false)
      end
    end
  end

  module SourceMethods
    def source_array
      return [] if source.blank?
      source.split("\n")
    end

    def apply_source_diff
      if FemboyFans.config.enable_autotagging? && !should_process_tags?
        tags = add_automatic_tags(tag_array)
        set_tag_string(tags.uniq.sort.join(" "))
      end

      return if source_diff.blank?

      diff = source_diff.gsub(/\r\n?/, "\n").gsub(/%0A/i, "\n").split(/(?:\r)?\n/)
      to_remove, to_add = diff.partition { |x| x =~ /\A-/i }
      to_remove = to_remove.pluck(1..-1)

      current_sources = source_array
      current_sources += to_add
      current_sources -= to_remove
      self.source = current_sources.join("\n")
    end

    def strip_source
      self.source = "" if source.blank?

      source.gsub!(/\r\n?/, "\n") # Normalize newlines
      source.gsub!(/%0A/i, "\n")  # Handle accidentally-encoded %0As from api calls (which would normally insert a literal %0A into the source)
      sources = source.split(/(?:\r)?\n/)
      gallery_sources = []
      submission_sources = []
      direct_sources = []
      additional_sources = []

      alternate_processors = []
      sources.map! do |src|
        src.unicode_normalize!(:nfc)
        src = src.try(:strip)
        alternate = Sources::Alternates.find(src)
        alternate_processors << alternate
        gallery_sources << alternate.gallery_url if alternate.gallery_url
        submission_sources << alternate.submission_url if alternate.submission_url
        direct_sources << alternate.direct_url if alternate.direct_url
        additional_sources += alternate.additional_urls if alternate.additional_urls
        alternate.original_url
      end
      sources = (sources + submission_sources + gallery_sources + direct_sources + additional_sources).compact.reject { |e| e.strip.empty? }.uniq
      alternate_processors.each do |alt_processor|
        sources = alt_processor.remove_duplicates(sources)
      end

      # Truncate sources to prevent abuse
      self.source = sources.pluck(0..2048).first(10).join("\n")
    end

    def copy_sources_to_parent
      return if parent_id.blank?
      parent.source += "\n#{source}"
    end
  end

  module PresenterMethods
    def presenter
      @presenter ||= PostPresenter.new(self)
    end

    def status_flags
      flags = []
      flags << "pending" if is_pending?
      flags << "flagged" if is_flagged?
      flags << "deleted" if is_deleted?
      flags.join(" ")
    end

    def pretty_rating
      {
        "s" => "Safe",
        "q" => "Questionable",
        "e" => "Explicit",
      }[rating]
    end
  end

  module TagMethods
    def should_process_tags?
      tag_string_changed? || locked_tags_changed? || tag_string_diff.present?
    end

    def tag_array
      @tag_array ||= TagQuery.scan(tag_string)
    end

    def tag_array_was
      @tag_array_was ||= TagQuery.scan(tag_string_in_database.presence || tag_string_before_last_save || "")
    end

    def tags
      Tag.where(name: tag_array)
    end

    def tag_ids
      tags.pluck(:id)
    end

    def tags_was
      Tag.where(name: tag_array_was)
    end

    TagCategory.category_names.each do |name|
      define_method("#{name}_tags") do
        tags.select { |t| t.category == TagCategory.get(name).id }
      end

      define_method("#{name}_tags_was") do
        tags_was.select { |t| t.category == TagCategory.get(name).id }
      end
    end

    def added_tags
      tags - tags_was
    end

    def decrement_tag_post_counts
      Tag.decrement_post_counts(tag_array)
    end

    def increment_tag_post_counts
      Tag.increment_post_counts(tag_array)
    end

    def update_tag_post_counts
      return if is_deleted?

      decrement_tags = tag_array_was - tag_array
      increment_tags = tag_array - tag_array_was
      Tag.increment_post_counts(increment_tags)
      Tag.decrement_post_counts(decrement_tags)
    end

    def update_pool_artists
      return unless artist_tags != artist_tags_was
      UpdatePoolArtistsJob.perform_later(id)
    end

    def update_pool_artists!
      pools.each do |pool|
        pool.update_artists(self, :tag_update)
      end
    end

    def update_tag_followers
      TagFollowerUpdateJob.perform_later(id)
    end

    def update_tag_followers!
      TagFollower.update_from_post!(self)
    end

    def set_tag_count(category, tagcount)
      send("tag_count_#{category}=", tagcount)
    end

    def inc_tag_count(category)
      set_tag_count(category, send("tag_count_#{category}") + 1)
    end

    def set_tag_counts(disable_cache: true)
      self.tag_count = 0
      TagCategory.category_names.each { |x| set_tag_count(x, 0) }
      categories = Tag.categories_for(tag_array, disable_cache: disable_cache)
      categories.each_value do |category|
        self.tag_count += 1
        inc_tag_count(TagCategory.reverse_mapping[category])
      end
    end

    def merge_old_changes
      @removed_tags = []

      if old_tag_string
        # If someone else committed changes to this post before we did,
        # then try to merge the tag changes together.
        current_tags = tag_array_was
        new_tags = tag_array
        old_tags = TagQuery.scan(old_tag_string)

        kept_tags = current_tags & new_tags
        @removed_tags = old_tags - kept_tags

        set_tag_string(((current_tags + new_tags) - old_tags + (current_tags & new_tags)).uniq.sort.join(" "))
      end

      if old_parent_id == ""
        old_parent_id = nil
      else
        old_parent_id = old_parent_id.to_i
      end
      if old_parent_id == parent_id
        self.parent_id = parent_id_before_last_save || parent_id_was
      end

      if old_source == source.to_s
        self.source = source_before_last_save || source_was
      end

      if old_rating == rating
        self.rating = rating_before_last_save || rating_was
      end
    end

    def apply_tag_diff
      @removed_tags = []
      return if tag_string_diff.blank?
      @tag_string_before_parse = remove_metatags(tag_string_diff.split).join(" ")

      current_tags = tag_array
      diff = TagQuery.scan(tag_string_diff.downcase)
      to_remove, to_add = diff.partition { |x| x =~ /\A-/i }
      to_remove = to_remove.pluck(1..-1)
      to_remove = TagAlias.to_aliased(to_remove)
      to_add = TagAlias.to_aliased(to_add)
      @removed_tags = to_remove
      current_tags += to_add
      current_tags -= to_remove
      set_tag_string(current_tags.uniq.sort.join(" "))
    end

    def reset_tag_array_cache
      @tag_array = nil
      @tag_array_was = nil
    end

    def set_tag_string(string) # rubocop:disable Naming/AccessorMethodName
      self.tag_string = string
      reset_tag_array_cache
    end

    def tag_count_not_insane
      return if do_not_version_changes || automated_edit
      return if do_not_version_changes || automated_edit

      max_count = FemboyFans.config.max_tags_per_post
      if TagQuery.scan(tag_string).size > max_count
        errors.add(:tag_string, "tag count exceeds maximum of #{max_count}")
        throw(:abort)
      end
      true
    end

    def normalize_tags
      @tag_string_before_parse = remove_metatags(tag_array - tag_array_was).join(" ") if tag_string_diff.blank?
      if !locked_tags.nil? && locked_tags.strip.blank?
        self.locked_tags = nil
      elsif locked_tags.present?
        remove_invalid_category_locked_tags
        locked = TagQuery.scan(locked_tags.downcase)
        to_remove, to_add = locked.partition { |x| x =~ /\A-/i }
        to_remove = to_remove.pluck(1..-1)
        to_remove = TagAlias.to_aliased(to_remove)
        @locked_to_remove = to_remove + to_remove.map { |tag_name| TagImplication.cached_descendants(tag_name) }.flatten
        @locked_to_add = TagAlias.to_aliased(to_add)
      end

      normalized_tags = TagQuery.scan(tag_string)
      normalized_tags = apply_casesensitive_metatags(normalized_tags)
      normalized_tags = normalized_tags.map(&:downcase)
      normalized_tags = remove_aspect_ratio_tags(normalized_tags)
      normalized_tags = filter_metatags(normalized_tags)
      normalized_tags = remove_negated_tags(normalized_tags)
      normalized_tags = remove_dnp_tags(normalized_tags)
      normalized_tags = TagAlias.to_aliased(normalized_tags)
      normalized_tags = apply_locked_tags(normalized_tags, @locked_to_add, @locked_to_remove)
      normalized_tags = %w[tagme] if normalized_tags.empty?
      normalized_tags = add_automatic_tags(normalized_tags)
      normalized_tags = TagImplication.with_descendants(normalized_tags)
      add_dnp_tags_to_locked(normalized_tags)
      normalized_tags -= @locked_to_remove if @locked_to_remove # Prevent adding locked tags through implications or aliases.
      normalized_tags = normalized_tags.compact.uniq
      normalized_tags = Tag.find_or_create_by_name_list(normalized_tags)
      normalized_tags = remove_invalid_tags(normalized_tags)
      set_tag_string(normalized_tags.map(&:name).uniq.sort.join(" "))
    end

    def remove_aspect_ratio_tags(tags)
      rejected = []
      tags = tags.reject do |tag|
        if tag =~ Post::ASPECT_RATIO_REGEX
          rejected << tag
          next true
        end
        false
      end
      warnings.add(:base, "Aspect ratios cannot be added to posts: #{rejected.join(', ')}") if rejected.any?
      tags
    end

    # Prevent adding these without an implication
    def remove_dnp_tags(tags)
      locked = locked_tags || ""
      # Don't remove dnp tags here if they would be later added through locked tags
      # to prevent the warning message from appearing when they didn't actually get removed
      if locked.exclude?("avoid_posting")
        tags -= ["avoid_posting"]
      end
      if locked.exclude?("conditional_dnp")
        tags -= ["conditional_dnp"]
      end
      tags
    end

    def add_dnp_tags_to_locked(tags)
      locked = TagQuery.scan((locked_tags || "").downcase)
      if tags.include?("avoid_posting")
        locked << "avoid_posting"
      end
      if tags.include?("conditional_dnp")
        locked << "conditional_dnp"
      end
      self.locked_tags = locked.uniq.join(" ") unless locked.empty?
    end

    def apply_locked_tags(tags, to_add, to_remove)
      if to_remove
        overlap = tags & to_remove
        n = overlap.size
        if n > 0
          warnings.add(:base, "Forcefully removed #{n} locked #{n == 1 ? 'tag' : 'tags'}: #{overlap.join(', ')}")
        end
        tags -= to_remove
      end
      if to_add
        missing = to_add - tags
        n = missing.size
        if n > 0
          warnings.add(:base, "Forcefully added #{n} locked #{n == 1 ? 'tag' : 'tags'}: #{missing.join(', ')}")
        end
        tags += to_add
      end
      tags
    end

    def remove_invalid_category_locked_tags
      locked = (locked_tags || "").downcase.split
      invalid = locked.select { |tag| Tag.category_for(tag.starts_with?("-") ? tag[1..] : tag) == TagCategory.invalid }
      unless invalid.empty?
        warnings.add(:base, "Forcefully removed #{invalid.length} invalid locked #{'tag'.pluralize(invalid.length)}: #{invalid.join(', ')}")
      end
      self.locked_tags = locked.reject { |tag| invalid.include?(tag) }.uniq.join(" ")
    end

    def remove_invalid_tags(tags)
      tags.select do |tag|
        unless tag.errors.empty?
          warnings.add(:base, "Can't add tag #{tag.name}: #{tag.errors.full_messages.join('; ')}")
        end
        tag.errors.empty?
      end
    end

    def remove_negated_tags(tags)
      @negated_tags, tags = tags.partition { |x| x =~ /\A-/i }
      @negated_tags = @negated_tags.pluck(1..-1)
      @negated_tags = TagAlias.to_aliased(@negated_tags)
      tags - @negated_tags
    end

    def add_automatic_tags(tags)
      return tags unless FemboyFans.config.enable_autotagging?

      tags -= %w[thumbnail low_res hi_res absurd_res superabsurd_res huge_filesize webm mp4 wide_image long_image invalid_source]

      if has_dimensions?
        tags << "superabsurd_res" if image_width >= 10_000 && image_height >= 10_000
        tags << "absurd_res" if image_width >= 3200 || image_height >= 2400
        tags << "hi_res" if image_width >= 1600 || image_height >= 1200
        tags << "low_res" if image_width <= 500 && image_height <= 500
        tags << "thumbnail" if image_width <= 250 && image_height <= 250

        if image_width >= 1024 && image_width.to_f / image_height >= 4
          tags << "wide_image"
          tags << "long_image"
        elsif image_height >= 1024 && image_height.to_f / image_width >= 4
          tags << "tall_image"
          tags << "long_image"
        end
      end

      if file_size >= 30.megabytes
        tags << "huge_filesize"
      end

      if is_webm?
        tags << "webm"
      end

      unless is_gif?
        tags -= ["animated_gif"]
      end

      unless is_png?
        tags -= ["animated_png"]
      end

      if invalid_source?
        tags << "invalid_source"
      end

      tags
    end

    # should_process_tags?
    def invalid_source?
      source_array.any? { |source| !%r{^-?https?://}.match(source) }
    end

    def apply_casesensitive_metatags(tags)
      casesensitive_metatags, tags = tags.partition { |x| x =~ /\A(?:source):/i }
      # Reuse the following metatags after the post has been saved
      casesensitive_metatags += tags.grep(/\A(?:newpool):/i)
      unless casesensitive_metatags.empty?
        case casesensitive_metatags[-1]
        when /^source:none$/i
          self.source = ""

        when /^source:"?([^"]*)"?$/i
          self.source = $1

        when /^newpool:(.+)$/i
          pool = Pool.find_by(name: $1)
          if pool.nil?
            Pool.create(name: $1, description: "This pool was automatically generated")
          end
        end
      end
      tags
    end

    def remove_metatags(tags)
      tags = tags.grep_v(/\A(?:-set|set|fav|-fav|upvote|downvote):/i)
      prefixed, unprefixed = tags.partition { |x| x =~ TagCategory.regexp }
      prefixed.map! { |tag| tag.sub(/\A#{TagCategory.regexp}:/, "") }
      prefixed + unprefixed
    end

    def filter_metatags(tags)
      @bad_type_changes = []
      @pre_metatags, tags = tags.partition { |x| x =~ /\A(?:rating|parent|-parent|-?locked):/i }
      tags = apply_categorization_metatags(tags)
      @post_metatags, tags = tags.partition { |x| x =~ /\A(?:-pool|pool|newpool|-set|set|fav|-fav|child|-child|upvote|downvote):/i }
      apply_pre_metatags
      unless @bad_type_changes.empty?
        bad_tags = @bad_type_changes.map { |x| "[[#{x}]]" }
        warnings.add(:base, "Failed to update the tag category for the following tags: #{bad_tags.join(', ')}. You can not edit the tag category of existing tags using prefixes. Please review usage of the tags, and if you are sure that the tag categories should be changed, then you can change them using the \"Tags\":/tags section of the website")
      end
      tags
    end

    def apply_categorization_metatags(tags)
      prefixed, unprefixed = tags.partition { |x| x =~ TagCategory.regexp }
      prefixed = Tag.find_or_create_by_name_list(prefixed)
      prefixed.map! do |tag|
        @bad_type_changes << tag.name if tag.errors.include?(:category)
        tag.name
      end
      prefixed + unprefixed
    end

    def apply_post_metatags
      return unless @post_metatags

      @post_metatags.each do |tag| # rubocop:disable Metrics/BlockLength
        case tag
        when /^-pool:(\d+)$/i
          pool = Pool.find_by(id: $1.to_i)
          if pool
            pool.remove!(self)
            if pool.errors.any?
              errors.add(:base, pool.errors.full_messages.join("; "))
            end
          end

        when /^-pool:(.+)$/i
          pool = Pool.find_by(name: $1)
          if pool
            pool.remove!(self)
            if pool.errors.any?
              errors.add(:base, pool.errors.full_messages.join("; "))
            end
          end

        when /^pool:(\d+)$/i
          pool = Pool.find_by(id: $1.to_i)
          if pool
            pool.add!(self)
            if pool.errors.any?
              errors.add(:base, pool.errors.full_messages.join("; "))
            end
          end

        when /^(?:new)?pool:(.+)$/i
          pool = Pool.find_by(name: $1)
          if pool
            pool.add!(self)
            if pool.errors.any?
              errors.add(:base, pool.errors.full_messages.join("; "))
            end
          end

        when /^set:(\d+)$/i
          set = PostSet.find_by(id: $1.to_i)
          if set&.can_edit_posts?(CurrentUser.user)
            set.add!(self)
            if set.errors.any?
              errors.add(:base, set.errors.full_messages.join("; "))
            end
          end

        when /^-set:(\d+)$/i
          set = PostSet.find_by(id: $1.to_i)
          if set&.can_edit_posts?(CurrentUser.user)
            set.remove!(self)
            if set.errors.any?
              errors.add(:base, set.errors.full_messages.join("; "))
            end
          end

        when /^set:(.+)$/i
          set = PostSet.find_by(shortname: $1)
          if set&.can_edit_posts?(CurrentUser.user)
            set.add!(self)
            if set.errors.any?
              errors.add(:base, set.errors.full_messages.join("; "))
            end
          end

        when /^-set:(.+)$/i
          set = PostSet.find_by(shortname: $1)
          if set&.can_edit_posts?(CurrentUser.user)
            set.remove!(self)
            if set.errors.any?
              errors.add(:base, set.errors.full_messages.join("; "))
            end
          end

        when /^child:none$/i
          children.each do |post|
            post.update!(parent_id: nil)
          end

        when /^-child:(.+)$/i
          children.numeric_attribute_matches(:id, $1).each do |post|
            post.update!(parent_id: nil)
          end

        when /^child:(.+)$/i
          Post.numeric_attribute_matches(:id, $1).where.not(id: id).limit(10).each do |post|
            post.update!(parent_id: id)
          end
        end
      end
    end

    def apply_pre_metatags
      return unless @pre_metatags

      @pre_metatags.each do |tag|
        case tag
        when /^parent:none$/i, /^parent:0$/i
          self.parent_id = nil

        when /^-parent:(\d+)$/i
          if parent_id == $1.to_i
            self.parent_id = nil
          end

        when /^parent:(\d+)$/i
          if $1.to_i != id && Post.exists?(["id = ?", $1.to_i])
            self.parent_id = $1.to_i
            remove_parent_loops
          end

        when /^rating:([qse])/i
          self.rating = $1

        when /^(-?)locked:notes?$/i
          self.is_note_locked = ($1 != "-") if CurrentUser.is_janitor?

        when /^(-?)locked:rating$/i
          self.is_rating_locked = ($1 != "-") if CurrentUser.is_janitor?

        when /^(-?)locked:status$/i
          self.is_status_locked = ($1 != "-") if CurrentUser.is_admin?

        end
      end
    end

    def has_tag?(*)
      TagQuery.has_tag?(tag_array, *)
    end

    def fetch_tags(*)
      TagQuery.fetch_tags(tag_array, *)
    end

    def ad_tag_string
      TagQuery.ad_tag_string(tag_array)
    end

    def add_tag(tag)
      set_tag_string("#{tag_string} #{tag}")
    end

    def remove_tag(tag)
      set_tag_string((tag_array - Array(tag)).join(" "))
    end

    def inject_tag_categories(tag_cats)
      @tag_categories = tag_cats
      @typed_tags = tag_array.group_by do |tag_name|
        @tag_categories[tag_name]
      end
    end

    def tag_categories
      @tag_categories ||= Tag.categories_for(tag_array)
    end

    def typed_tags(category_id)
      @typed_tags ||= {}
      @typed_tags[category_id] ||= tag_array.select do |tag|
        tag_categories[tag] == category_id
      end
    end

    def copy_tags_to_parent
      return if parent_id.blank?
      parent.tag_string += " #{tag_string}"
    end
  end

  module FavoriteMethods
    def clean_fav_string!
      array = fav_string.split.uniq
      self.fav_string = array.join(" ")
      self.fav_count = array.size
    end

    def favorited_by?(user_id = CurrentUser.id)
      !!(fav_string =~ /(?:\A| )fav:#{user_id}(?:\Z| )/)
    end

    alias is_favorited? favorited_by?

    def append_user_to_fav_string(user_id)
      self.fav_string = (fav_string + " fav:#{user_id}").strip
      clean_fav_string!
    end

    def delete_user_from_fav_string(user_id)
      self.fav_string = fav_string.gsub(/(?:\A| )fav:#{user_id}(?:\Z| )/, " ").strip
      clean_fav_string!
    end

    # users who favorited this post, ordered by users who favorited it first
    def favorited_users
      favorited_user_ids = fav_string.scan(/\d+/).map(&:to_i)
      visible_users = User.find(favorited_user_ids).reject(&:hide_favorites?)
      visible_users.index_by(&:id).slice(*favorited_user_ids).values
    end

    def remove_from_favorites
      Favorite.where(post_id: id).delete_all
      user_ids = fav_string.scan(/\d+/)
      User.where(id: user_ids).update_all("favorite_count = favorite_count - 1")
    end
  end

  module UploaderMethods
    def initialize_uploader
      if uploader_id.blank?
        self.uploader_id = CurrentUser.id
        self.uploader_ip_addr = CurrentUser.ip_addr
      end
    end

    def uploader_name
      if association(:uploader).loaded?
        return uploader&.name || "Anonymous"
      end
      User.id_to_name(uploader_id)
    end
  end

  module SetMethods
    def set_ids
      pool_string.scan(/set:(\d+)/).map { |set| set[0].to_i }
    end

    def post_sets
      @post_sets ||= if pool_string.blank?
                       PostSet.none
                     else
                       PostSet.where(id: set_ids)
                     end
    end

    def belongs_to_post_set(set)
      pool_string =~ /(?:\A| )set:#{set.id}(?:\z| )/
    end

    def add_set!(set, force: false)
      return if belongs_to_post_set(set) && !force
      with_lock do
        self.pool_string = "#{pool_string} set:#{set.id}".strip
      end
    end

    def remove_set!(set)
      with_lock do
        self.pool_string = (pool_string.split - ["set:#{set.id}"]).join(" ").strip
      end
    end

    def give_post_sets_to_parent
      transaction do
        post_sets.find_each do |set|
          set.remove([id])
          set.add([parent.id]) if parent_id.present? && set.transfer_on_delete
          set.save!
        rescue StandardError
          # Ignore set errors due to things like set post count
        end
      end
    end

    def remove_from_post_sets
      post_sets.find_each do |set|
        set.remove!(self)
      end
    end
  end

  module PoolMethods
    def pool_ids
      pool_string.scan(/pool:(\d+)/).map { |pool| pool[0].to_i }
    end

    def pools
      @pools ||= if pool_string.blank?
                   Pool.none
                 else
                   Pool.where(id: pool_ids)
                 end
    end

    def has_active_pools?
      pools.any?
    end

    def belongs_to_pool?(pool)
      pool_string =~ /(?:\A| )pool:#{pool.id}(?:\Z| )/
    end

    def add_pool!(pool)
      return if belongs_to_pool?(pool)

      with_lock do
        self.pool_string = "#{pool_string} pool:#{pool.id}".strip
      end
    end

    def remove_pool!(pool)
      return unless belongs_to_pool?(pool)
      return unless CurrentUser.user.can_remove_from_pools?

      with_lock do
        self.pool_string = pool_string.gsub(/(?:\A| )pool:#{pool.id}(?:\Z| )/, " ").strip
      end
    end

    def remove_from_all_pools
      pools.find_each do |pool|
        pool.remove!(self)
      end
    end
  end

  module VoteMethods
    def own_vote(user = CurrentUser.user)
      return nil unless user
      v = vote_string.scan(/(?:\A| )(up|down|locked):#{user.id}(?:\Z| )/).map { $1 }.first
      return nil if v.nil?
      %w[down locked up].index(v) - 1
    end

    def is_voted?(user = CurrentUser.user)
      return false unless user
      own_vote(user).present?
    end

    def is_voted_down?(user = CurrentUser.user)
      return false unless user
      own_vote(user) == -1
    end

    def is_voted_up?(user = CurrentUser.user)
      return false unless user
      own_vote(user) == 1
    end

    def is_vote_locked?(user = CurrentUser.user)
      return false unless user
      own_vote(user) == 0
    end

    def append_user_to_vote_string(user_id, type)
      if vote_string =~ /(?:\A| )(locked|up|down):#{user_id}(?:\Z| )/
        return if $1 == type
        self.vote_string = vote_string.gsub(/(?:\A| )(locked|up|down):#{user_id}(?:\Z| )/, " #{type}:#{user_id} ")
      else
        self.vote_string = vote_string + " #{type}:#{user_id}"
      end
      clean_vote_string!
    end

    def delete_user_from_vote_string(user_id)
      self.vote_string = vote_string.gsub(/(?:\A| )(locked|up|down):#{user_id}(?:\Z| )/, " ").strip
      clean_vote_string!
    end

    def clean_vote_string!
      array = vote_string.split.uniq { |x| x[/\d+/] }
      self.vote_string = array.join(" ")
      self.up_score = array.count { |x| x =~ /up/ }
      self.down_score = array.count { |x| x =~ /down/ }
      self.score = up_score - down_score
    end
  end

  module CountMethods
    def fast_count(tags = "", enable_safe_mode: CurrentUser.safe_mode?)
      tags = tags.to_s
      tags += " rating:s" if enable_safe_mode
      tags += " -status:deleted" unless TagQuery.has_metatag?(tags, "status", "-status")
      tags = TagQuery.normalize(tags)

      cache_key = "pfc:#{tags}"
      count = Cache.fetch(cache_key)
      if count.nil?
        count = Post.tag_match(tags).count_only
        expiry = count.seconds.clamp(3.minutes, 20.hours).to_i
        Cache.write(cache_key, count, expires_in: expiry)
      end
      count
    rescue TagQuery::CountExceededError
      0
    end
  end

  module ParentMethods
    # A parent has many children. A child belongs to a parent.
    # A parent cannot have a parent.
    #
    # After expunging a child:
    # - Move favorites to parent.
    # - Does the parent have any children?
    #   - Yes: Done.
    #   - No: Update parent's has_children flag to false.
    #
    # After expunging a parent:
    # - Move favorites to the first child.
    # - Reparent all children to the first child.

    def update_has_children_flag
      update(has_children: children.exists?, has_active_children: children.undeleted.exists?)
    end

    def blank_out_nonexistent_parents
      if parent_id.present? && parent.nil?
        self.parent_id = nil
      end
    end

    def remove_parent_loops
      if parent.present? && parent.parent_id.present? && parent.parent_id == id
        parent.parent_id = nil
        parent.save
      end
    end

    def update_parent_on_destroy
      parent&.update_has_children_flag
    end

    def update_children_on_destroy
      return if children.blank?

      eldest = children[0]
      siblings = children[1..]

      eldest.update(parent_id: nil)
      Post.where(id: siblings).find_each { |p| p.update(parent_id: eldest.id) }
      # Post.where(id: siblings).update(parent_id: eldest.id) # XXX rails 5
    end

    def update_parent_on_save
      return unless saved_change_to_parent_id? || saved_change_to_is_deleted?

      parent.update_has_children_flag if parent.present?
      Post.find(parent_id_before_last_save).update_has_children_flag if parent_id_before_last_save.present?
    end

    def give_favorites_to_parent
      TransferFavoritesJob.perform_later(id, CurrentUser.id)
    end

    def give_favorites_to_parent!
      return if parent.nil?

      FavoriteManager.give_to_parent!(self)
      PostEvent.add(id, CurrentUser.user, :favorites_moved, { parent_id: parent_id })
      PostEvent.add(parent_id, CurrentUser.user, :favorites_received, { child_id: id })
    end

    def give_votes_to_parent
      TransferVotesJob.perform_later(id, CurrentUser.id)
    end

    def give_votes_to_parent!
      return if parent.nil?

      VoteManager::Posts.give_to_parent!(self)
    end

    def parent_exists?
      Post.exists?(parent_id)
    end

    def has_visible_children?
      return true if has_active_children?
      return true if has_children? && CurrentUser.is_approver?
      return true if has_children? && is_deleted?
      false
    end

    def has_visible_children
      has_visible_children?
    end

    def inject_children(ids)
      @children_ids = ids.map(&:id).join(" ")
    end

    def children_ids
      if has_children?
        @children_ids ||= children.map(&:id).join(" ")
      end
    end
  end

  module DeletionMethods
    def backup_post_data_destroy
      post_data = {
        id:            id,
        description:   description,
        md5:           md5,
        tags:          tag_string,
        height:        image_height,
        width:         image_width,
        file_size:     file_size,
        sources:       source,
        approver_id:   approver_id,
        locked_tags:   locked_tags,
        rating:        rating,
        parent_id:     parent_id,
        change_seq:    change_seq,
        is_deleted:    is_deleted,
        is_pending:    is_pending,
        duration:      duration,
        fav_count:     fav_count,
        comment_count: comment_count,
      }
      DestroyedPost.create!(post_id: id, post_data: post_data, md5: md5,
                            uploader_ip_addr: uploader_ip_addr, uploader_id: uploader_id,
                            destroyer_id: CurrentUser.id, destroyer_ip_addr: CurrentUser.ip_addr,
                            upload_date: created_at)
    end

    def expunge!
      if is_status_locked?
        errors.add(:is_status_locked, "; cannot delete post")
        return false
      end

      transaction do
        backup_post_data_destroy
      end

      transaction do
        Post.without_timeout do
          PostEvent.add(id, CurrentUser.user, :expunged)

          update_children_on_destroy
          decrement_tag_post_counts
          remove_from_all_pools
          remove_from_post_sets
          remove_from_favorites
          destroy
          update_parent_on_destroy
        end
      end
    end

    def protect_file?
      is_deleted?
    end

    def delete!(reason, options = {})
      if is_status_locked? && !options.fetch(:force, false)
        errors.add(:is_status_locked, "; cannot delete post")
        return false
      end

      if reason.blank?
        if pending_flag.blank?
          errors.add(:base, "Cannot delete with given reason when no active flag exists.")
          return
        end
        if pending_flag.reason =~ /uploading_guidelines/
          errors.add(:base, "Cannot delete with given reason when the flag is for uploading guidelines.")
          return
        end
        reason = pending_flag.reason
      end

      force_flag = options.fetch(:force, false)
      Post.with_timeout(30_000) do
        transaction do
          flag = flags.create(reason: reason, reason_name: "deletion", is_resolved: false, is_deletion: true, force_flag: force_flag)

          if flag.errors.any?
            raise(PostFlag::Error, flag.errors.full_messages.join("; "))
          end

          update(
            is_deleted: true,
            is_pending: false,
            is_flagged: false,
          )
          decrement_tag_post_counts
          move_files_on_delete
          PostEvent.add(id, CurrentUser.user, :deleted, { reason: reason })
        end
      end

      # XXX This must happen *after* the `is_deleted` flag is set to true (issue #3419).
      # We don't care if these fail per-se so they are outside the transaction.
      User.where(id: uploader_id).update_all("post_deleted_count = post_deleted_count + 1")
      if options[:move_favorites]
        give_favorites_to_parent
        give_votes_to_parent
        give_post_sets_to_parent
      end
      reject_pending_replacements
    end

    def reject_pending_replacements
      replacements.where(status: "pending").update_all(status: "rejected")
    end

    def undelete!(options = {})
      if is_status_locked? && !options.fetch(:force, false)
        errors.add(:is_status_locked, "; cannot undelete post")
        return
      end

      if !CurrentUser.is_admin? && uploader_id == CurrentUser.id
        raise(User::PrivilegeError, "You cannot undelete a post you uploaded")
      end

      unless is_deleted
        errors.add(:base, "Post is not deleted")
        return
      end

      transaction do
        self.is_deleted = false
        self.is_pending = false
        self.approver_id = CurrentUser.id
        flags.each(&:resolve!)
        increment_tag_post_counts
        save
        approvals.create(user: CurrentUser.user)
        PostEvent.add(id, CurrentUser.user, :undeleted)
      end
      move_files_on_undelete
      User.where(id: uploader_id).update_all("post_deleted_count = post_deleted_count - 1")
    end

    def deletion_flag
      flags.order(id: :desc).first
    end

    def pending_flag
      flags.unresolved.order(id: :desc).first
    end
  end

  module VersionMethods
    def create_version(force: false)
      return if do_not_version_changes == true
      if new_record? || force
        create_new_version
      elsif automated_edit
        # the original tag string is not useful for automated edits
        self.original_tag_string = nil
        latest = versions.last
        if saved_change_to_mergable_attributes? && !saved_change_to_unmergable_attributes? && latest.updater_id == CurrentUser.user.id && latest.basic? && !latest.first?
          merge_post_version(versions.last)
          return
        end
      end
      if saved_change_to_watched_attributes?
        create_new_version
      end
    end

    def saved_change_to_watched_attributes?
      saved_change_to_unmergable_attributes? || saved_change_to_mergable_attributes?
    end

    def saved_change_to_unmergable_attributes?
      saved_change_to_rating? || saved_change_to_parent_id? || saved_change_to_description?
    end

    def saved_change_to_mergable_attributes?
      saved_change_to_source? || saved_change_to_tag_string? || saved_change_to_locked_tags?
    end

    def create_new_version
      # This function name is misleading, this directly creates the version.
      # Previously there was a queue involved, now there isn't.
      PostVersion.queue(self)
    end

    def merge_post_version(version)
      PostVersion.merge(version, self)
    end

    def revert_to(target)
      if id != target.post_id
        raise(RevertError, "You cannot revert to a previous version of another post.")
      end

      self.tag_string = target.tags
      self.rating = target.rating
      self.source = target.source
      self.parent_id = target.parent_id
      self.description = target.description
      self.edit_reason = "Revert to version #{target.version}"
    end

    def revert_to!(target)
      revert_to(target)
      save!
    end
  end

  module NoteMethods
    def has_notes?
      last_noted_at.present?
    end

    def copy_notes_to(other_post, copy_tags: NOTE_COPY_TAGS)
      if id == other_post.id
        errors.add(:base, "Source and destination posts are the same")
        return false
      end
      unless has_notes?
        errors.add(:post, "has no notes")
        return false
      end

      transaction do
        notes.active.each do |note|
          note.copy_to(other_post)
        end

        dummy = Note.new
        if notes.active.length == 1
          dummy.body = "Copied 1 note from post ##{id}."
        else
          dummy.body = "Copied #{notes.active.length} notes from post ##{id}."
        end
        dummy.is_active = false
        dummy.post_id = other_post.id
        dummy.x = dummy.y = dummy.width = dummy.height = 0
        dummy.save

        copy_tags.each do |tag|
          other_post.remove_tag(tag)
          other_post.add_tag(tag) if has_tag?(tag)
        end

        other_post.save
      end
    end
  end

  module ApiMethods
    def hidden_attributes
      list = super + %i[pool_string fav_string]
      unless visible?
        list += %i[md5 file_ext]
      end
      super + list
    end

    def method_attributes
      list = super + %i[has_large has_visible_children children_ids pool_ids is_favorited? is_voted_up? is_voted_down?]
      if visible?
        list += %i[file_url large_file_url preview_file_url]
      end
      list
    end

    def minimal_attributes
      preview_dims = preview_dimensions
      hash = {
        created_ago:    "#{Class.new.extend(ActionView::Helpers::DateHelper).time_ago_in_words(created_at)} ago",
        created_at:     created_at.iso8601,
        down_score:     down_score,
        file_ext:       file_ext,
        file_size:      file_size,
        flags:          status_flags,
        height:         image_height,
        id:             id,
        preview_height: preview_dims[0],
        preview_width:  preview_dims[1],
        rating:         rating,
        score:          score,
        status:         status,
        tags:           tag_string,
        up_score:       up_score,
        uploader:       uploader_name,
        uploader_id:    uploader_id,
        width:          image_width,
      }

      if visible?
        hash[:md5] = md5
        hash[:preview_file_url] = preview_file_url
        hash[:large_file_url] = large_file_url
        hash[:cropped_file_url] = crop_file_url
        hash[:file_url] = file_url
      end
      hash
    end

    def alternate_samples
      alternates = {}
      FemboyFans.config.video_rescales.each do |k, v|
        next unless has_sample_size?(k)
        dims = scaled_sample_dimensions(v)
        alternates[k] = {
          type:   "video",
          height: dims[1],
          width:  dims[0],
          urls:   visible? ? [scaled_url_ext(k, "webm"), scaled_url_ext(k, "mp4")] : [nil, nil],
        }
      end
      if has_sample_size?("original")
        fixed_dims = scaled_sample_dimensions([image_width, image_height])
        alternates["original"] = {
          type:   "video",
          height: fixed_dims[1],
          width:  fixed_dims[0],
          urls:   visible? ? [nil, file_url_ext("mp4")] : [nil, nil],
        }
      end
      FemboyFans.config.image_rescales.each do |k, v|
        next unless has_sample_size?(k)
        dims = scaled_sample_dimensions(v)
        alternates[k] = {
          type:   "image",
          height: dims[1],
          width:  dims[0],
          url:    visible? ? scaled_url_ext(k, "webp") : nil,
        }
      end
      alternates
    end

    def status
      if is_pending?
        "pending"
      elsif is_deleted?
        "deleted"
      elsif is_flagged?
        "flagged"
      else
        "active"
      end
    end

    def serializable_hash(*)
      preview_height, preview_width = preview_dimensions
      {
        id:              id,
        created_at:      created_at,
        updated_at:      updated_at,
        file:            {
          width:  image_width,
          height: image_height,
          ext:    file_ext,
          size:   file_size,
          md5:    md5,
          url:    visible? ? file_url : nil,
        },
        preview:         {
          width:  preview_width,
          height: preview_height,
          url:    visible? ? preview_file_url : nil,
        },
        sample:          {
          has:        has_large?,
          height:     large_image_height,
          width:      large_image_width,
          url:        visible? ? large_file_url : nil,
          alternates: alternate_samples,
        },
        crop:            {
          has:    has_cropped?,
          height: FemboyFans.config.small_image_width,
          width:  FemboyFans.config.small_image_width,
          url:    visible? ? crop_file_url : nil,
        },
        score:           {
          up:    up_score,
          down:  down_score,
          total: score,
        },
        views:           {
          daily: daily_views,
          total: total_views,
        },
        tags:            TagCategory.category_names.index_with { |category| typed_tags(TagCategory.get(category).id) },
        locked_tags:     locked_tags&.split || [],
        change_seq:      change_seq,
        flags:           {
          pending:       is_pending,
          flagged:       is_flagged,
          note_locked:   is_note_locked,
          status_locked: is_status_locked,
          rating_locked: is_rating_locked,
          deleted:       is_deleted,
        },
        rating:          rating,
        fav_count:       fav_count,
        sources:         source.split("\n"),
        pools:           pool_ids,
        relationships:   {
          parent_id:           parent_id,
          has_children:        has_children,
          has_active_children: has_active_children,
          children:            children_ids&.split&.map(&:to_i) || [],
        },
        approver_id:     approver_id,
        uploader_id:     uploader_id,
        description:     description,
        comment_count:   visible_comment_count(CurrentUser.user),
        is_favorited:    is_favorited?,
        own_vote:        own_vote,
        has_notes:       has_notes?,
        duration:        duration&.to_f,
        framecount:      framecount,
        thumbnail_frame: thumbnail_frame,
        qtags:           qtags,
        upload_url:      upload_url,
      }
    end
  end

  module SearchMethods
    # returns one single post
    def random
      key = Digest::MD5.hexdigest(Time.now.to_f.to_s)
      random_up(key) || random_down(key)
    end

    def random_up(key)
      where("md5 < ?", key).reorder("md5 desc").first
    end

    def random_down(key)
      where("md5 >= ?", key).reorder("md5 asc").first
    end

    def sample(query, sample_size)
      tag_match_system("#{query} order:random", free_tags_count: 1).limit(sample_size).relation
    end

    # unflattens the tag_string into one tag per row.
    def with_unflattened_tags
      joins("CROSS JOIN unnest(string_to_array(tag_string, ' ')) AS tag")
    end

    def pending
      where(is_pending: true)
    end

    def flagged
      where(is_flagged: true)
    end

    def pending_or_flagged
      pending.or(flagged)
    end

    def undeleted
      where("is_deleted = ?", false)
    end

    def deleted
      where("is_deleted = ?", true)
    end

    def has_notes
      where.not(last_noted_at: nil)
    end

    def for_user(user_id)
      where("uploader_id = ?", user_id)
    end

    def sql_raw_tag_match(tag)
      where("string_to_array(posts.tag_string, ' ') @> ARRAY[?]", tag)
    end

    def tag_match_system(query, free_tags_count: 0)
      tag_match(query, free_tags_count: free_tags_count, enable_safe_mode: false, always_show_deleted: true)
    end

    def tag_match(query, resolve_aliases: true, free_tags_count: 0, enable_safe_mode: CurrentUser.safe_mode?, always_show_deleted: false)
      ElasticPostQueryBuilder.new(
        query,
        resolve_aliases:     resolve_aliases,
        free_tags_count:     free_tags_count,
        enable_safe_mode:    enable_safe_mode,
        always_show_deleted: always_show_deleted,
      ).search
    end

    def tag_match_sql(query)
      PostQueryBuilder.new(query).search
    end
  end

  module IqdbMethods
    extend ActiveSupport::Concern

    module ClassMethods
      def remove_iqdb(post_id)
        if IqdbProxy.enabled?
          IqdbRemoveJob.perform_later(post_id)
        end
      end
    end

    def update_iqdb_async
      if IqdbProxy.enabled? && has_preview?
        IqdbUpdateJob.perform_later(id)
      end
    end

    def remove_iqdb_async
      Post.remove_iqdb(id)
    end
  end

  module PostEventMethods
    def create_post_events
      if saved_change_to_is_rating_locked?
        action = is_rating_locked? ? :rating_locked : :rating_unlocked
        PostEvent.add(id, CurrentUser.user, action)
      end
      if saved_change_to_is_status_locked?
        action = is_status_locked? ? :status_locked : :status_unlocked
        PostEvent.add(id, CurrentUser.user, action)
      end
      if saved_change_to_is_note_locked?
        action = is_note_locked? ? :note_locked : :note_unlocked
        PostEvent.add(id, CurrentUser.user, action)
      end
      if saved_change_to_is_comment_disabled?
        action = is_comment_disabled? ? :comment_disabled : :comment_enabled
        PostEvent.add(id, CurrentUser.user, action)
      end
      if saved_change_to_is_comment_locked?
        action = is_comment_locked? ? :comment_locked : :comment_unlocked
        PostEvent.add(id, CurrentUser.user, action)
      end
      if saved_change_to_bg_color?
        PostEvent.add(id, CurrentUser.user, :changed_bg_color, { bg_color: bg_color })
      end
      if saved_change_to_thumbnail_frame?
        PostEvent.add(id, CurrentUser.user, :changed_thumbnail_frame, { old_thumbnail_frame: thumbnail_frame_before_last_save, new_thumbnail_frame: thumbnail_frame })
      end
    end
  end

  module ValidationMethods
    def fix_bg_color
      if bg_color.blank?
        self.bg_color = nil
      end
    end

    def post_is_not_its_own_parent
      if !new_record? && id == parent_id
        errors.add(:base, "Post cannot have itself as a parent")
        false
      end
    end

    def updater_can_change_rating
      # Don't forbid changes if the rating lock was just now set in the same update.
      if rating_changed? && is_rating_locked? && !is_rating_locked_changed?
        errors.add(:rating, "is locked and cannot be changed. Unlock the post first.")
      end
    end

    def added_tags_are_valid
      # Load this only once since it isn't cached
      added = added_tags
      added_invalid_tags = added.select { |t| t.category == TagCategory.invalid }
      new_tags = added.select { |t| t.post_count <= 0 }
      new_general_tags = new_tags.select { |t| t.category == TagCategory.general }
      new_artist_tags = new_tags.select { |t| t.category == TagCategory.artist }
      # See https://github.com/e621ng/e621ng/issues/494
      # If the tag is fresh it's save to assume it was created with a prefix
      repopulated_tags = new_tags.select { |t| t.category != TagCategory.general && t.category != TagCategory.meta && t.created_at < 10.seconds.ago }

      if added_invalid_tags.present?
        n = added_invalid_tags.size
        tag_wiki_links = added_invalid_tags.map { |tag| "[[#{tag.name}]]" }
        warnings.add(:base, "Added #{n} invalid #{'tag'.pluralize(n)}. See the wiki page for each tag for help on resolving these: #{tag_wiki_links.join(', ')}")
      end

      if new_general_tags.present?
        n = new_general_tags.size
        tag_wiki_links = new_general_tags.map { |tag| "[[#{tag.name}]]" }
        warnings.add(:base, "Created #{n} new #{'tag'.pluralize(n)}: #{tag_wiki_links.join(', ')}")
      end

      if repopulated_tags.present?
        n = repopulated_tags.size
        tag_wiki_links = repopulated_tags.map { |tag| "[[#{tag.name}]]" }
        warnings.add(:base, "Repopulated #{n} old #{'tag'.pluralize(n)}: #{tag_wiki_links.join(', ')}")
      end

      new_artist_tags.each do |tag|
        if tag.artist.blank?
          warnings.add(:base, "Artist [[#{tag.name}]] requires an artist entry. \"Create new artist entry\":[/artists/new?artist%5Bname%5D=#{CGI.escape(tag.name)}]")
        end
      end
    end

    def removed_tags_are_valid
      attempted_removed_tags = @removed_tags + @negated_tags
      unremoved_tags = tag_array & attempted_removed_tags

      if unremoved_tags.present?
        unremoved_tags_list = unremoved_tags.map { |t| "[[#{t}]]" }.to_sentence
        warnings.add(:base, "#{unremoved_tags_list} could not be removed. Check for implications and locked tags and try again")
      end
    end

    def has_artist_tag
      return unless new_record?
      return if tags.any? { |t| t.category == TagCategory.artist }

      warnings.add(:base, 'Artist tag is required. "Click here":/help/tags#catchange if you need help changing the category of an tag. Ask on the forum if you need naming help')
    end

    def has_enough_tags
      return unless new_record?

      if tags.count { |t| t.category == TagCategory.general } < 10
        warnings.add(:base, "Uploads must have at least 10 general tags. Read the \"Tagging Checklist\":/help/tagging_checklist for information on tagging your uploads")
      end
    end
  end

  module ViewMethods
    def total_views
      (Reports.get_post_views(id) || 0).to_i
    end

    def daily_views(date = Time.now)
      (Reports.get_post_views_rank(date).find { |r| r["post"] == id }.try(:[], "count") || 0).to_i
    end
  end

  module QTagMethods
    def update_qtags
      self.qtags = DText.parse(description, qtags: true)[:qtags]
    end
  end

  include PostFileMethods
  include FileMethods
  include ImageMethods
  include ApprovalMethods
  include SourceMethods
  include PresenterMethods
  include TagMethods
  include FavoriteMethods
  include UploaderMethods
  include PoolMethods
  include SetMethods
  include VoteMethods
  include ParentMethods
  include DeletionMethods
  include VersionMethods
  include NoteMethods
  include ApiMethods
  include IqdbMethods
  include ValidationMethods
  include PostEventMethods
  include DocumentStore::Model
  include PostIndex
  include ViewMethods
  include QTagMethods
  extend CountMethods
  extend SearchMethods

  def safeblocked?
    return true if FemboyFans.config.safe_mode? && rating != "s"
    CurrentUser.safe_mode? && (rating != "s" || has_tag?(*FemboyFans.config.safeblocked_tags))
  end

  def deleteblocked?
    !FemboyFans.config.can_user_see_post?(CurrentUser.user, self)
  end

  def loginblocked?
    CurrentUser.is_anonymous? && (hide_from_anonymous? || FemboyFans.config.user_needs_login_for_post?(self))
  end

  def visible?
    return false if loginblocked?
    return false if safeblocked?
    return false if deleteblocked?
    true
  end

  def comments_visible_to?(_user)
    return true if CurrentUser.is_moderator?
    !is_comment_disabled?
  end

  def allow_sample_resize?
    true
  end

  def force_original_size?
    false
  end

  def reload(options = nil)
    super
    reset_tag_array_cache
    @locked_to_add = nil
    @locked_to_remove = nil
    @pools = nil
    @post_sets = nil
    @tag_categories = nil
    @typed_tags = nil
    self
  end

  def mark_as_translated(params)
    add_tag("translation_check") if params["translation_check"].to_s.truthy?
    remove_tag("translation_check") if params["translation_check"].to_s.falsy?

    add_tag("partially_translated") if params["partially_translated"].to_s.truthy?
    remove_tag("partially_translated") if params["partially_translated"].to_s.falsy?

    if has_tag?("translation_check", "partially_translated")
      add_tag("translation_request")
      remove_tag("translated")
    else
      add_tag("translated")
      remove_tag("translation_request")
    end

    save
  end

  def uploader_linked_artists
    artist_tags.filter_map(&:artist).select { |artist| artist.linked_user_id == uploader_id }
  end

  def uploader_name_matches_artists?
    return false if uploader_id.nil? || uploader_linked_artists.any?
    typed_tags(TagCategory.artist).include?(uploader_name.downcase)
  end

  def avoid_posting_artists
    AvoidPosting.active.where(artist_name: artist_tags.map(&:name))
  end

  def followed_tags(user)
    user.followed_tags.where(tag: tags)
  end

  def download_filename
    name = id.to_s
    artists = typed_tags(TagCategory.artist)
    copyrights = typed_tags(TagCategory.copyright)
    characters = typed_tags(TagCategory.character)
    species = typed_tags(TagCategory.species)
    name += "-#{artists.join('-')}" if artists.present?
    name += "-#{copyrights.join('-')}" if copyrights.present?
    name += "-#{characters.join('-')}" if characters.present?
    name += "-#{species.join('-')}" if species.present?
    "#{name}.#{file_ext}"
  end

  def self.validate_thumbnail_frame(post, frame)
    max = post.framecount > 1000 ? (post.framecount / 10).ceil : post.framecount
    return [false, max] if post.framecount.blank? || frame < 1 || frame > max
    [true, max]
  end

  def validate_thumbnail_frame
    return if thumbnail_frame.blank?
    valid, max = Post.validate_thumbnail_frame(self, thumbnail_frame)
    unless valid
      if framecount.blank? || framecount == 0
        errors.add(:thumbnail_frame, "cannot be used on posts without a framecount")
        return
      end
      errors.add(:thumbnail_frame, "must be in first 10% of video") if framecount > 1000 && thumbnail_frame > max
      errors.add(:thumbnail_frame, "must be between 1 and #{max}") if thumbnail_frame < 1 || thumbnail_frame > max
    end
  end

  def flaggable_for_guidelines?
    true
  end

  def visible_comment_count(user)
    comments_visible_to?(user) ? comment_count : 0
  end

  def self.search_uploaders(params)
    q = all
    q.where_user(:uploader_id, :user, params)
  end
end
