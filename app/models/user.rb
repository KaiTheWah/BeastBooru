# frozen_string_literal: true

class User < ApplicationRecord
  class Error < StandardError; end
  class MFAError < StandardError; end

  class PrivilegeError < StandardError
    attr_accessor :message

    def initialize(msg = nil)
      @message = "Access Denied: #{msg}" if msg
    end
  end

  class PrivacyModeError < PrivilegeError
    def initialize(msg = "This user has privacy mode enabled")
      super
    end
  end

  module Levels
    ANONYMOUS    = 0
    BANNED       = 1
    RESTRICTED   = 5
    MEMBER       = 10
    TRUSTED      = 15
    FORMER_STAFF = 19
    JANITOR      = 20
    MODERATOR    = 30
    SYSTEM       = 35
    ADMIN        = 40
    OWNER        = 50

    def self.id_to_name(level)
      name = constants.find { |c| const_get(c) == level }.to_s.titleize
      return "Unknown: #{level}" if name.blank?
      name
    end

    def self.name_to_id(name)
      const_get(name.upcase)
    rescue NameError
      nil
    end

    def self.hash
      constants.to_h { |key| [key.to_s.titleize, const_get(key)] }.sort_by { |_name, level| level }.to_h
    end

    def self.staff_hash
      hash.select { |_name, level| level >= min_staff_level }
    end

    def self.min_staff_level
      JANITOR
    end

    def self.level_class(level)
      level = id_to_name(level) if level.is_a?(Integer)
      "user-#{level.downcase}"
    end
  end

  # Used for `before_action :<role>_only`. Must have a corresponding `is_<role>?` method.
  Roles = Levels.constants.map(&:downcase) + [
    :approver,
  ]

  module Preferences
    mattr_accessor :settable, default: []
    mattr_accessor :private, default: []
    mattr_accessor :public, default: []

    def self.pref(value, settable: true, private: true, public: false)
      self.settable << value if settable
      self.private << value if private
      self.public << value if public
      value
    end

    DESCRIPTION_COLLAPSED_INITIALLY  = pref(1 << 0)
    HIDE_COMMENTS                    = pref(1 << 1)
    SHOW_HIDDEN_COMMENTS             = pref(1 << 2)
    RECEIVE_EMAIL_NOTIFICATIONS      = pref(1 << 3)
    ENABLE_KEYBOARD_NAVIGATION       = pref(1 << 4)
    ENABLE_PRIVACY_MODE              = pref(1 << 5)
    STYLE_USERNAMES                  = pref(1 << 6)
    ENABLE_AUTOCOMPLETE              = pref(1 << 7)
    CAN_APPROVE_POSTS                = pref(1 << 8, settable: false, public: true)
    UNRESTRICTED_UPLOADS             = pref(1 << 9, settable: false, public: true)
    DISABLE_CROPPED_THUMBNAILS       = pref(1 << 10)
    ENABLE_SAFE_MODE                 = pref(1 << 11)
    DISABLE_RESPONSIVE_MODE          = pref(1 << 12)
    NO_FLAGGING                      = pref(1 << 13, settable: false, private: false)
    DISABLE_USER_DMAILS              = pref(1 << 14, public: true)
    ENABLE_COMPACT_UPLOADER          = pref(1 << 15, settable: false)
    NO_REPLACEMENTS                  = pref(1 << 16, settable: false, private: false)
    MOVE_RELATED_THUMBNAILS          = pref(1 << 17)
    ENABLE_HOVER_ZOOM                = pref(1 << 18)
    HOVER_ZOOM_SHIFT                 = pref(1 << 19)
    HOVER_ZOOM_STICKY_SHIFT          = pref(1 << 20)
    HOVER_ZOOM_PLAY_AUDIO            = pref(1 << 21)
    CAN_MANAGE_AIBUR                 = pref(1 << 22, settable: false, public: true)
    FORCE_NAME_CHANGE                = pref(1 << 23, settable: false, private: false)
    SHOW_POST_UPLOADER               = pref(1 << 24)
    GO_TO_RECENT_FORUM_POST          = pref(1 << 25)
    DISABLE_COLORS                   = pref(1 << 26)
    NO_AIBUR_VOTING                  = pref(1 << 27, settable: false, private: false)
    EMAIL_VERIFIED                   = pref(1 << 28, settable: false, public: true)

    def self.map
      constants.to_h { |name| [name.to_s.downcase, const_get(name)] }
    end

    def self.list
      map.keys.map(&:to_sym)
    end

    def self.settable_list
      map.filter { |_name, value| settable.include?(value) }.keys.map(&:to_sym)
    end

    def self.private_list
      map.filter { |_name, value| private.include?(value) }.keys.map(&:to_sym)
    end

    def self.public_list
      map.filter { |_name, value| public.include?(value) }.keys.map(&:to_sym)
    end

    def self.index(value)
      value = const_get(value) unless value.is_a?(Integer)
      Math.log2(value).to_i
    end
  end

  include FemboyFans::HasBitFlags
  has_bit_flags(Preferences.map, field: "bit_prefs")

  attr_accessor :password, :old_password, :validate_email_format, :is_admin_edit

  after_initialize :initialize_attributes, if: :new_record?
  before_validation :sanitize_upload_notifications, if: :will_save_change_to_upload_notifications?

  validates :email, presence: { if: :enable_email_verification? }
  validates :email, uniqueness: { case_sensitive: false, if: :enable_email_verification? }
  validates :email, format: { with: /\A.+@[^ ,;@]+\.[^ ,;@]+\z/, if: :enable_email_verification? }
  validates :email, length: { maximum: 100 }
  validate :validate_email_address_allowed, on: %i[create update], if: ->(rec) { (rec.new_record? && rec.email.present?) || (rec.email.present? && rec.email_changed?) }

  validates :name, user_name: true, on: :create
  validates :default_image_size, inclusion: { in: %w[large fit fitv original] }
  validates :per_page, inclusion: { in: 1..FemboyFans.config.max_per_page }
  validates :comment_threshold, presence: true
  validates :comment_threshold, numericality: { only_integer: true, less_than: 50_000, greater_than: -50_000 }
  validates :password, length: { minimum: 6, maximum: 128, if: ->(rec) { rec.new_record? || rec.password.present? || rec.old_password.present? } }, unless: :is_system?
  validates :password, confirmation: true, unless: :is_system?
  validates :password_confirmation, presence: { if: ->(rec) { rec.new_record? || rec.old_password.present? } }, unless: :is_system?
  validate :validate_ip_addr_is_not_banned, on: :create
  validate :validate_sock_puppets, on: :create, if: -> { FemboyFans.config.enable_sock_puppet_validation? && !is_system? }
  validate :validate_prefs, if: :will_save_change_to_bit_prefs?
  before_validation :normalize_blacklisted_tags, if: ->(rec) { rec.blacklisted_tags_changed? }
  before_validation :staff_cant_disable_dmail
  before_validation :blank_out_nonexistent_avatars
  validates :blacklisted_tags, length: { maximum: FemboyFans.config.blacklisted_tags_max_size }
  validates :custom_style, length: { maximum: FemboyFans.config.custom_style_max_size }
  validates :profile_about, length: { maximum: FemboyFans.config.user_about_max_size }
  validates :profile_artinfo, length: { maximum: FemboyFans.config.user_about_max_size }
  validates :time_zone, inclusion: { in: ActiveSupport::TimeZone.all.map(&:name) }
  validates :upload_notifications, inclusion: { in: -> { User.upload_notifications_options } }
  before_create :promote_to_owner_if_first_user
  before_create :encrypt_password_on_create
  before_update :encrypt_password_on_update
  # after_create :notify_sock_puppets
  after_update :log_update
  after_save :update_cache
  after_update(if: ->(rec) { rec.saved_change_to_profile_about? || rec.saved_change_to_profile_artinfo? || rec.saved_change_to_blacklisted_tags? }) do |rec|
    UserTextVersion.create_version(rec)
  end

  has_many :api_keys, dependent: :destroy
  has_one :dmail_filter
  has_many :sent_dmails, ->(user) { owned_by(user) }, class_name: "Dmail", foreign_key: "from_id"
  has_many :received_dmails, ->(user) { owned_by(user) }, class_name: "Dmail", foreign_key: "to_id"
  has_one :recent_ban, -> { order("bans.id desc") }, class_name: "Ban"
  has_many :bans, -> { order("bans.id desc") }
  has_many :dmails, -> { order("dmails.id desc") }, foreign_key: "owner_id"
  has_many :favorites, -> { order(id: :desc) }
  has_many :feedback, class_name: "UserFeedback", dependent: :destroy
  has_many :comments, foreign_key: "creator_id"
  has_many :forum_posts, -> { order("forum_posts.created_at, forum_posts.id") }, foreign_key: "creator_id"
  has_many :forum_topic_visits
  has_many :tickets, foreign_key: "creator_id"
  has_many :note_versions, foreign_key: "updater_id"
  has_many :posts, foreign_key: "uploader_id"
  has_many :post_approvals, dependent: :destroy
  has_many :post_disapprovals, dependent: :destroy
  has_many :post_replacements, foreign_key: :creator_id
  has_many :post_sets, -> { order(name: :asc) }, foreign_key: :creator_id
  has_many :post_versions
  has_many :post_votes
  has_many :staff_notes, -> { active.order("staff_notes.id desc") }
  has_many :user_name_change_requests, -> { order(id: :asc) }
  has_many :text_versions, -> { order(id: :desc) }, class_name: "UserTextVersion"
  has_many :artists, foreign_key: "linked_user_id"
  has_many :blocks, class_name: "UserBlock"
  has_many :followed_tags, class_name: "TagFollower"
  has_many :notifications
  has_many :user_events

  belongs_to :avatar, class_name: "Post", optional: true
  accepts_nested_attributes_for :dmail_filter

  module BanMethods
    def validate_ip_addr_is_not_banned
      if IpBan.is_banned?(CurrentUser.ip_addr)
        errors.add(:base, "IP address is banned")
        false
      end
    end

    def ban!
      return false if is_banned?
      self.level = Levels::BANNED
      ModAction.log!(:user_ban, self, user_id: id)
      save(validate: false)
    end

    def unban!(ack: false)
      return false unless is_banned?
      self.level = Levels::MEMBER
      ModAction.log!(:user_unban, self, user_id: id) unless ack
      save(validate: false)
    end

    def ban_expired?
      is_banned? && recent_ban.try(:expired?)
    end
  end

  module NameMethods
    extend ActiveSupport::Concern

    module ClassMethods
      def name_to_id(name)
        normalized_name = normalize_name(name)
        Cache.fetch("uni:#{normalized_name}", expires_in: 4.hours) do
          User.where("lower(name) = ?", normalized_name).pick(:id)
        end
      end

      def name_or_id_to_id(name)
        if name =~ /\A!\d+\z/
          return name[1..].to_i
        end
        User.name_to_id(name)
      end

      def name_or_id_to_id_forced(name)
        if name =~ /\A\d+\z/
          return name.to_i
        end
        User.name_to_id(name)
      end

      def id_to_name(user_id)
        RequestStore[:id_name_cache] ||= {}
        if RequestStore[:id_name_cache].key?(user_id)
          return RequestStore[:id_name_cache][user_id]
        end
        name = Cache.fetch("uin:#{user_id}", expires_in: 4.hours) do
          User.where(id: user_id).pick(:name) || FemboyFans.config.default_guest_name
        end
        RequestStore[:id_name_cache][user_id] = name
        name
      end

      def find_by_normalized_name(name)
        where("lower(name) = ?", normalize_name(name)).first
      end

      def find_by_normalized_name_or_id(name)
        if name =~ /\A!\d+\z/
          where("id = ?", name[1..].to_i).first
        else
          find_by(name: name)
        end
      end

      def normalize_name(name)
        name.to_s.downcase.strip.tr(" ", "_").to_s
      end
    end

    def pretty_name
      name.gsub(/([^_])_+(?=[^_])/, "\\1 \\2")
    end

    def update_cache
      Cache.write("uin:#{id}", name, expires_in: 4.hours)
      Cache.write("uni:#{User.normalize_name(name)}", id, expires_in: 4.hours)
    end
  end

  module PasswordMethods
    def password_token
      # noinspection RubyArgCount
      Zlib.crc32(bcrypt_password_hash)
    end

    def bcrypt_password
      BCrypt::Password.new(bcrypt_password_hash)
    end

    def encrypt_password_on_create
      self.password_hash = ""
      self.bcrypt_password_hash = User.bcrypt(password)
    end

    def encrypt_password_on_update
      return if password.blank?
      return if old_password.blank?

      if bcrypt_password == old_password
        self.bcrypt_password_hash = User.bcrypt(password)
        true
      else
        errors.add(:old_password, "is incorrect")
        false
      end
    end

    def upgrade_password(pass)
      update_columns(password_hash: "", bcrypt_password_hash: User.bcrypt(pass))
    end
  end

  module AuthenticationMethods
    extend ActiveSupport::Concern

    module ClassMethods
      def authenticate(name, pass)
        user = find_by(name: name)
        if user&.bcrypt_password == pass
          user
        end
      end

      def bcrypt(pass)
        BCrypt::Password.create(pass)
      end
    end

    def authenticate_api_key(key)
      return false unless is_verified?
      api_key = api_keys.find_by(key: key)
      api_key.present? && ActiveSupport::SecurityUtils.secure_compare(api_key.key, key) && [self, api_key]
    end
  end

  module LevelMethods
    extend ActiveSupport::Concern

    Levels.constants.each do |constant|
      next if Levels.const_get(constant) < Levels::MEMBER

      define_method("is_#{constant.downcase}?") do
        level >= Levels.const_get(constant)
      end
    end

    module ClassMethods
      def anonymous
        FemboyFans.config.anonymous_user
      end

      def system
        FemboyFans.config.system_user
      end

      def owner
        User.find_by!(level: Levels::OWNER)
      end
    end

    def promote_to!(new_level, options = {})
      UserPromotion.new(self, CurrentUser.user, new_level, options).promote!
    end

    def promote_to_owner_if_first_user
      return if Rails.env.test?

      if name != FemboyFans.config.system_user_name && !User.exists?(level: Levels::OWNER)
        self.level = Levels::OWNER
        self.created_at = 2.weeks.ago
        self.can_approve_posts = true
        self.unrestricted_uploads = true
        self.can_manage_aibur = true
      end
    end

    def level_string_was
      level_string(level_was)
    end

    def level_string(value = nil)
      User::Levels.id_to_name(value || level)
    end

    def level_string_pretty
      return level_string if title.blank?
      %(<span title="#{level_string}">#{title}</span>).html_safe
    end

    def level_name
      Levels.level_name(level)
    end

    def is_anonymous?
      level == Levels::ANONYMOUS
    end

    def is_banned?
      level == Levels::BANNED
    end

    def is_restricted?
      level == Levels::RESTRICTED
    end

    def is_staff?
      level >= Levels.min_staff_level
    end

    def is_approver?
      can_approve_posts?
    end

    def staff_cant_disable_dmail
      self.disable_user_dmails = false if is_janitor?
    end

    def level_css_class
      Levels.level_class(level)
    end
  end

  module EmailMethods
    def is_verified?
      id.present? && email_verified?
    end

    def mark_unverified!
      update(email_verified: false)
    end

    def mark_verified!
      update(email_verified: true)
    end

    def enable_email_verification?
      # Allow admins to edit users with blank/duplicate emails
      return false if is_admin_edit && !email_changed?
      FemboyFans.config.enable_email_verification? && validate_email_format
    end

    def validate_email_address_allowed
      if EmailBlacklist.is_banned?(email)
        errors.add(:base, "Email address may not be used")
        false
      end
    end
  end

  module BlacklistMethods
    def normalize_blacklisted_tags
      self.blacklisted_tags = TagAlias.to_aliased_query(blacklisted_tags, comments: true) if blacklisted_tags.present?
    end

    def is_blacklisting_user?(user)
      return false if blacklisted_tags.blank?
      bltags = blacklisted_tags.split("\n").map(&:downcase)
      strings = %W[user:#{user.name.downcase} user:!#{user.id} userid:#{user.id}]
      strings.any? { |str| bltags.include?(str) }
    end
  end

  module ForumMethods
    def has_forum_been_updated?
      return false unless is_member?
      max_updated_at = ForumTopic.visible(self).unmuted.order(updated_at: :desc).first&.updated_at
      return false if max_updated_at.nil?
      return true if last_forum_read_at.nil?
      max_updated_at > last_forum_read_at
    end

    def has_viewed_topic?(id, last_updated)
      @topic_views ||= forum_topic_visits.pluck(:forum_topic_id, :last_read_at).to_h
      @topic_views.key?(id) && @topic_views[id] >= last_updated
    end
  end

  module ThrottleMethods
    def throttle_reason(reason, timeframe = "hourly")
      reasons = {
        REJ_NEWBIE:  "can not yet perform this action. Account is too new",
        REJ_LIMITED: "have reached the #{timeframe} limit for this action",
      }
      reasons.fetch(reason, "unknown throttle reason, please report this as a bug")
    end

    def upload_reason_string(reason)
      reasons = {
        REJ_UPLOAD_HOURLY: "have reached your hourly upload limit",
        REJ_UPLOAD_EDIT:   "have no remaining tag edits available",
        REJ_UPLOAD_LIMIT:  "have reached your upload limit",
        REJ_UPLOAD_NEWBIE: "cannot upload during your first week",
      }
      reasons.fetch(reason, "unknown upload rejection reason")
    end
  end

  module MFAMethods
    MAX_BACKUP_CODES = 6
    # number of dash delimited sections
    BACKUP_CODE_PARTS = 2
    # length of each section
    BACKUP_CODE_SECTION_LENGTH = 4

    def mfa
      @mfa ||= MFA.new(mfa_secret, username: name, last_used_at: mfa_last_used_at) if mfa_secret.present?
    end

    def update_mfa_secret!(secret, request)
      with_lock do
        update!(mfa_secret: secret)
        remove_instance_variable(:@mfa) if instance_variable_defined?(:@mfa)

        if mfa_secret_before_last_save.nil?
          UserEvent.create_from_request!(self, :mfa_enable, request)
          regenerate_backup_codes!(request)
        elsif secret.nil?
          UserEvent.create_from_request!(self, :mfa_disable, request)
          update!(backup_codes: nil)
        else
          UserEvent.create_from_request!(self, :mfa_update, request)
        end
      end
    end

    def verify_backup_code(code)
      return false unless backup_codes.present? && backup_codes.include?(code)
      self.backup_codes -= [code]
      save!
    end

    def generate_backup_codes(max_codes: MAX_BACKUP_CODES, parts: BACKUP_CODE_PARTS, length: BACKUP_CODE_SECTION_LENGTH)
      max_codes.times.map { parts.times.map { SecureRandom.hex(length / 2) }.join("-") }
    end

    def regenerate_backup_codes!(request, max_codes: MAX_BACKUP_CODES, parts: BACKUP_CODE_PARTS, length: BACKUP_CODE_SECTION_LENGTH)
      with_lock do
        update!(backup_codes: generate_backup_codes(max_codes: max_codes, parts: parts, length: length))
        UserEvent.create_from_request!(self, :backup_codes_generate, request)
      end
    end
  end

  module LimitMethods
    def younger_than(duration)
      return false if FemboyFans.config.disable_age_checks?
      younger_than!(duration)
    end

    def younger_than!(duration)
      created_at > duration.ago
    end

    def older_than(duration)
      return true if FemboyFans.config.disable_age_checks?
      older_than!(duration)
    end

    def older_than!(duration)
      created_at < duration.ago
    end

    def self.create_user_throttle(name, limiter, checker, newbie_duration)
      define_method(:"#{name}_limit", limiter)

      define_method(:"can_#{name}_with_reason") do
        return true if FemboyFans.config.disable_throttles?
        return send(checker) if checker && send(checker)
        return :REJ_NEWBIE if newbie_duration && younger_than(newbie_duration)
        return :REJ_LIMITED if send("#{name}_limit") <= 0
        true
      end
    end

    def token_bucket
      @token_bucket ||= UserThrottle.new({ prefix: "thtl:", duration: 1.minute }, self)
    end

    def general_bypass_throttle?
      is_trusted?
    end

    create_user_throttle(:artist_edit, -> { FemboyFans.config.artist_edit_limit - ArtistVersion.for_user(id).where("updated_at > ?", 1.hour.ago).count },
                         :general_bypass_throttle?, 7.days)
    create_user_throttle(:post_edit, -> { FemboyFans.config.post_edit_limit - PostVersion.for_user(id).where("updated_at > ?", 1.hour.ago).count },
                         :general_bypass_throttle?, 7.days)
    create_user_throttle(:post_appeal, -> { FemboyFans.config.post_appeal_limit - PostAppeal.for_user(id).where("updated_at > ?", 1.hour.ago).count },
                         :general_bypass_throttle?, 7.days)
    create_user_throttle(:wiki_edit, -> { FemboyFans.config.wiki_edit_limit - WikiPageVersion.for_user(id).where("updated_at > ?", 1.hour.ago).count },
                         :general_bypass_throttle?, 7.days)
    create_user_throttle(:pool, -> { FemboyFans.config.pool_limit - Pool.for_user(id).where("created_at > ?", 1.hour.ago).count },
                         :is_janitor?, 7.days)
    create_user_throttle(:pool_edit, -> { FemboyFans.config.pool_edit_limit - PoolVersion.for_user(id).where("updated_at > ?", 1.hour.ago).count },
                         :is_janitor?, 3.days)
    create_user_throttle(:pool_post_edit, -> { FemboyFans.config.pool_post_edit_limit - PoolVersion.for_user(id).where("updated_at > ?", 1.hour.ago).group(:pool_id).count(:pool_id).length },
                         :general_bypass_throttle?, 7.days)
    create_user_throttle(:note_edit, -> { FemboyFans.config.note_edit_limit - NoteVersion.for_user(id).where("updated_at > ?", 1.hour.ago).count },
                         :general_bypass_throttle?, 3.days)
    create_user_throttle(:comment, -> { FemboyFans.config.member_comment_limit - Comment.for_creator(id).where("created_at > ?", 1.hour.ago).count },
                         :general_bypass_throttle?, 7.days)
    create_user_throttle(:forum_post, -> { FemboyFans.config.member_comment_limit - ForumPost.for_user(id).where("created_at > ?", 1.hour.ago).count },
                         :general_bypass_throttle?, 3.days)
    create_user_throttle(:dmail_minute, -> { FemboyFans.config.dmail_minute_limit - Dmail.sent_by_id(id).where("created_at > ?", 1.minute.ago).count },
                         :is_janitor?, 7.days)
    create_user_throttle(:dmail, -> { FemboyFans.config.dmail_limit - Dmail.sent_by_id(id).where("created_at > ?", 1.hour.ago).count },
                         :is_janitor?, 7.days)
    create_user_throttle(:dmail_day, -> { FemboyFans.config.dmail_day_limit - Dmail.sent_by_id(id).where("created_at > ?", 1.day.ago).count },
                         :is_janitor?, 7.days)
    create_user_throttle(:comment_vote, -> { FemboyFans.config.comment_vote_limit - CommentVote.for_user(id).where("created_at > ?", 1.hour.ago).count },
                         :general_bypass_throttle?, 3.days)
    create_user_throttle(:post_vote, -> { FemboyFans.config.post_vote_limit - PostVote.for_user(id).where("created_at > ?", 1.hour.ago).count },
                         :general_bypass_throttle?, nil)
    create_user_throttle(:post_flag, -> { FemboyFans.config.post_flag_limit - PostFlag.for_creator(id).where("created_at > ?", 1.hour.ago).count },
                         :can_approve_posts?, 3.days)
    create_user_throttle(:ticket, -> { FemboyFans.config.ticket_limit - Ticket.for_creator(id).where("created_at > ?", 1.hour.ago).count },
                         :general_bypass_throttle?, 3.days)
    create_user_throttle(:suggest_tag, -> { FemboyFans.config.tag_suggestion_limit - (TagAlias.for_creator(id).where("created_at > ?", 1.hour.ago).count + TagImplication.for_creator(id).where("created_at > ?", 1.hour.ago).count + BulkUpdateRequest.for_creator(id).where("created_at > ?", 1.hour.ago).count) },
                         :is_janitor?, 7.days)
    create_user_throttle(:forum_vote, -> { FemboyFans.config.forum_vote_limit - ForumPostVote.by(id).where("created_at > ?", 1.hour.ago).count },
                         :general_bypass_throttle?, 3.days)

    def can_remove_from_pools?
      is_member? && older_than(7.days)
    end

    def can_view_flagger?(flagger_id)
      is_janitor? || flagger_id == id
    end

    def can_view_flagger_on_post?(flag)
      is_janitor? || flag.creator_id == id || flag.is_deletion
    end

    def can_replace?
      !no_replacements?
    end

    def can_view_staff_notes?
      is_staff?
    end

    def can_handle_takedowns?
      is_owner?
    end

    def can_edit_avoid_posting_entries?
      is_owner?
    end

    def can_revert_post_versions?
      is_member?
    end

    def can_upload_with_reason
      return :REJ_UPLOAD_HOURLY if hourly_upload_limit <= 0 && !FemboyFans.config.disable_throttles?
      return true if unrestricted_uploads? || is_admin?
      return :REJ_UPLOAD_NEWBIE if younger_than(7.days)
      return :REJ_UPLOAD_EDIT if !is_trusted? && post_edit_limit <= 0 && !FemboyFans.config.disable_throttles?
      return :REJ_UPLOAD_LIMIT if upload_limit <= 0 && !FemboyFans.config.disable_throttles?
      true
    end

    def hourly_upload_limit
      @hourly_upload_limit ||= begin
        post_count = posts.where("created_at >= ?", 1.hour.ago).count
        replacement_count = can_approve_posts? ? 0 : post_replacements.where("created_at >= ? and status != ?", 1.hour.ago, "original").count
        FemboyFans.config.hourly_upload_limit - post_count - replacement_count
      end
    end

    def upload_limit
      pieces = upload_limit_pieces
      base_upload_limit + (pieces[:approved] / 10) - (pieces[:deleted] / 4) - pieces[:pending]
    end

    def upload_limit_pieces
      @upload_limit_pieces ||= begin
        deleted_count = Post.deleted.for_user(id).count
        rejected_replacement_count = post_replacement_rejected_count
        replaced_penalize_count = own_post_replaced_penalize_count
        unapproved_count = Post.pending_or_flagged.for_user(id).count
        unapproved_replacements_count = post_replacements.pending.count
        approved_count = Post.for_user(id).where(is_flagged: false, is_deleted: false, is_pending: false).count

        {
          deleted:        deleted_count + replaced_penalize_count + rejected_replacement_count,
          deleted_ignore: own_post_replaced_count - replaced_penalize_count,
          approved:       approved_count,
          pending:        unapproved_count + unapproved_replacements_count,
        }
      end
    end

    def uploaders_list_pieces
      @uploaders_list_pieces ||= {
        pending:              Post.pending.for_user(id).count,
        approved:             Post.for_user(id).where(is_flagged: false, is_deleted: false, is_pending: false).count,
        deleted:              Post.deleted.for_user(id).count,
        flagged:              Post.flagged.for_user(id).count,
        replaced:             own_post_replaced_count,
        replacement_pending:  post_replacements.pending.count,
        replacement_rejected: post_replacement_rejected_count,
        replacement_promoted: post_replacements.promoted.count,
      }
    end

    def post_upload_throttle
      @post_upload_throttle ||= is_trusted? ? hourly_upload_limit : [hourly_upload_limit, post_edit_limit].min
    end

    def tag_query_limit
      FemboyFans.config.tag_query_limit
    end

    def favorite_limit
      100_000
    end

    def api_regen_multiplier
      1
    end

    def api_burst_limit
      # can make this many api calls at once before being bound by
      # api_regen_multiplier refilling your pool
      if is_former_staff?
        120
      elsif is_trusted?
        90
      else
        60
      end
    end

    def remaining_api_limit
      token_bucket.uncached_count
    end

    def statement_timeout
      if is_former_staff?
        9_000
      elsif is_trusted?
        6_000
      else
        3_000
      end
    end
  end

  module CountMethods
    def wiki_page_version_count
      wiki_update_count
    end

    def post_active_count
      post_upload_count - post_deleted_count
    end

    def post_upload_count
      post_count
    end

    def note_version_count
      note_update_count
    end

    def artist_version_count
      artist_update_count
    end

    def pool_version_count
      pool_update_count
    end

    def flag_count
      post_flag_count
    end

    def positive_feedback_count
      feedback.active.positive.count
    end

    def neutral_feedback_count
      feedback.active.neutral.count
    end

    def negative_feedback_count
      feedback.active.negative.count
    end

    def deleted_feedback_count
      feedback.deleted.count
    end

    def refresh_counts!
      self.class.without_timeout do
        User.where(id: id).update_all(
          post_count:                       Post.for_user(id).count,
          post_deleted_count:               Post.for_user(id).deleted.count,
          post_update_count:                PostVersion.for_user(id).count,
          post_flag_count:                  PostFlag.for_creator(id).count,
          favorite_count:                   Favorite.for_user(id).count,
          wiki_update_count:                WikiPageVersion.for_user(id).count,
          note_update_count:                NoteVersion.for_user(id).count,
          forum_post_count:                 ForumPost.for_user(id).count,
          comment_count:                    Comment.for_creator(id).count,
          pool_update_count:                PoolVersion.for_user(id).count,
          set_count:                        PostSet.owned(self).count,
          artist_update_count:              ArtistVersion.for_user(id).count,
          own_post_replaced_count:          PostReplacement.for_uploader_on_approve(id).count,
          own_post_replaced_penalize_count: PostReplacement.penalized.for_uploader_on_approve(id).count,
          post_replacement_rejected_count:  post_replacements.rejected.count,
          ticket_count:                     Ticket.for_creator(id).count,
        )
      end
    end
  end

  module SearchMethods
    def admins
      where("level = ?", Levels::ADMIN)
    end

    def with_email(email)
      if email.blank?
        where("FALSE")
      else
        where("lower(email) = lower(?)", email)
      end
    end

    def search(params)
      q = super

      q = q.attribute_matches(:level, params[:level])

      if params[:about_me].present?
        q = q.attribute_matches(:profile_about, params[:about_me]).or(attribute_matches(:profile_artinfo, params[:about_me]))
      end

      if params[:avatar_id].present?
        q = q.where(avatar_id: params[:avatar_id])
      end

      if params[:email_matches].present?
        q = q.where_ilike(:email, params[:email_matches])
      end

      if params[:name_matches].present?
        q = q.where_ilike(:name, normalize_name(params[:name_matches]))
      end

      if params[:min_level].present?
        q = q.where("level >= ?", params[:min_level].to_i)
      end

      if params[:max_level].present?
        q = q.where("level <= ?", params[:max_level].to_i)
      end

      bitprefs_length = Preferences.constants.length
      bitprefs_include = nil
      bitprefs_exclude = nil

      %i[can_approve_posts unrestricted_uploads].each do |x|
        next if params[x].blank?
        attr_idx = Preferences.index(x.upcase)
        if params[x].to_s.truthy?
          bitprefs_include ||= "0" * bitprefs_length
          bitprefs_include[attr_idx] = "1"
        elsif params[x].to_s.falsy?
          bitprefs_exclude ||= "0" * bitprefs_length
          bitprefs_exclude[attr_idx] = "1"
        end
      end

      if bitprefs_include
        bitprefs_include.reverse!
        q = q.where("bit_prefs::bit(:len) & :bits::bit(:len) = :bits::bit(:len)",
                    { len: bitprefs_length, bits: bitprefs_include })
      end

      if bitprefs_exclude
        bitprefs_exclude.reverse!
        q = q.where("bit_prefs::bit(:len) & :bits::bit(:len) = 0::bit(:len)",
                    { len: bitprefs_length, bits: bitprefs_exclude })
      end

      if params[:ip_addr].present?
        q = q.where("last_ip_addr <<= ?", params[:ip_addr])
      end

      case params[:order]
      when "name"
        q = q.order("name")
      when "post_upload_count"
        q = q.order("post_count desc")
      when "note_count"
        q = q.order("note_update_count desc")
      when "post_update_count"
        q = q.order("post_update_count desc")
      else
        q = q.apply_basic_order(params)
      end

      q
    end
  end

  concerning :SockPuppetMethods do
    attr_writer :validate_sock_puppets

    def validate_sock_puppets
      return if @validate_sock_puppets == false

      if User.where(last_ip_addr: CurrentUser.ip_addr).exists?(["created_at > ?", 1.day.ago])
        errors.add(:last_ip_addr, "was used recently for another account and cannot be reused for another day")
      end
    end
  end

  module BlockMethods
    def is_blocking?(target)
      blocks.exists?(target: target)
    end

    def block_for(target)
      blocks.find_by(target: target)
    end

    def is_blocking_comments_from?(target)
      is_blocking?(target) && block_for(target).hide_comments?
    end

    def is_blocking_forum_topics_from?(target)
      is_blocking?(target) && block_for(target).hide_forum_topics?
    end

    def is_blocking_forum_posts_from?(target)
      is_blocking?(target) && block_for(target).hide_forum_posts?
    end

    def is_blocking_messages_from?(target)
      is_blocking?(target) && block_for(target).disable_messages?
    end

    def is_suppressing_mentions_from?(target)
      is_blocking?(target) && block_for(target).suppress_mentions?
    end
  end

  module LogChanges
    def log_name_change
      ModAction.log!(:user_name_change, self, user_id: id)
    end

    def log_update
      if saved_change_to_base_upload_limit?
        ModAction.log!(:user_upload_limit_change, self, old_upload_limit: base_upload_limit_before_last_save, upload_limit: base_upload_limit, user_id: id)
      end

      return unless is_admin_edit

      if saved_change_to_profile_about? || saved_change_to_profile_artinfo?
        ModAction.log!(:user_text_change, self, user_id: id)
      end

      if saved_change_to_blacklisted_tags
        ModAction.log!(:user_blacklist_change, self, user_id: id)
      end

      if saved_change_to_title
        StaffAuditLog.log!(:user_title_change, CurrentUser.user, user_id: id, title: title)
      end

      if force_name_change_was != force_name_change && force_name_change?
        StaffAuditLog.log!(:force_name_change, CurrentUser.user, user_id: id)
      end
    end
  end

  module FollowerMethods
    def tag_followed?(tag)
      tag = tag.name if tag.is_a?(Tag)
      if tag.to_s =~ /\A\d+\z/
        followed_tags.joins(:tag).exists?(tag: { id: tag })
      else
        followed_tags.joins(:tag).exists?(tag: { name: tag })
      end
    end

    def followed_tags_list
      followed_tags.map(&:tag_name)
    end
  end

  module NotificationMethods
    def has_unread_notifications?
      unread_notification_count > 0
    end
  end

  include BanMethods
  include NameMethods
  include PasswordMethods
  include AuthenticationMethods
  include LevelMethods
  include EmailMethods
  include BlacklistMethods
  include ForumMethods
  include LimitMethods
  include CountMethods
  include BlockMethods
  include LogChanges
  include FollowerMethods
  include NotificationMethods
  include MFAMethods
  extend SearchMethods
  extend ThrottleMethods

  def set_per_page
    if per_page.nil?
      self.per_page = FemboyFans.config.posts_per_page
    end

    true
  end

  def blank_out_nonexistent_avatars
    if avatar_id.present? && avatar.nil?
      self.avatar_id = nil
    end
  end

  def has_mail?
    unread_dmail_count > 0
  end

  def hide_favorites?
    return false if CurrentUser.is_moderator?
    return true if is_banned?
    enable_privacy_mode? && CurrentUser.user.id != id
  end

  def hide_followed_tags?
    return false if CurrentUser.is_moderator?
    enable_privacy_mode? && CurrentUser.user.id != id
  end

  def compact_uploader?
    post_upload_count >= 10 && enable_compact_uploader?
  end

  def enable_hover_zoom_shift?
    enable_hover_zoom? && hover_zoom_shift?
  end

  def enable_hover_zoom_form
    return false unless enable_hover_zoom?
    return "shift" if enable_hover_zoom_shift?
    true
  end

  def enable_hover_zoom_form=(value)
    if value == "shift"
      self.enable_hover_zoom = true
      self.hover_zoom_shift = true
    else
      self.enable_hover_zoom = value.to_s.truthy?
      self.hover_zoom_shift = false
    end
  end

  def initialize_attributes
    return if Rails.env.test?
    FemboyFans.config.customize_new_user(self)
  end

  def presenter
    @presenter ||= UserPresenter.new(self)
  end

  # Users with invalid names may be automatically renamed in the future.
  def name_error
    errors = UserNameValidator.validate(self)
    errors << "Forced change by administrator" if force_name_change?
    errors.join("; ").presence
  end

  def can_admin_edit?(user)
    # owners can edit anyone
    return true if user.is_owner?
    # no one else can edit admins
    return false if is_admin?
    # admins can edit anyone else
    user.is_admin?
  end

  def validate_prefs
    errors.add(:can_manage_aibur, "Members cannot have the \"Manage Tag Change Requests\" permission") if level == Levels::MEMBER && can_manage_aibur?
    errors.add(:no_aibur_voting, "User cannot have both \"Manage Tag Change Requests\" & \"No AIBUR Voting\"") if can_manage_aibur? && no_aibur_voting?
  end

  def clear_favorites
    ClearUserFavoritesJob.perform_later(self)
  end

  def self.email_verified
    where("bit_prefs & :value = :value", { value: Preferences::EMAIL_VERIFIED })
  end

  def self.email_not_verified
    where("bit_prefs & :value != :value", { value: Preferences::EMAIL_VERIFIED })
  end

  def self.upload_notifications_options
    %w[post_delete post_undelete post_approve post_unapprove appeal_accept appeal_reject replacement_approve replacement_reject replacement_promote]
  end

  def notify_for_upload(model, type)
    return unless upload_notifications.include?(type.to_s)
    notifications.create!(category: type, data: { post_id: model.respond_to?(:post_id) ? model.post_id : nil, "#{model.class.name.underscore}_id": model.id }.compact_blank)
  end

  def sanitize_upload_notifications
    self.upload_notifications = upload_notifications.compact_blank.uniq
  end

  def self.available_includes
    %i[artists bans feedback]
  end
end
