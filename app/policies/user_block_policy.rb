# frozen_string_literal: true

# record: User
class UserBlockPolicy < ApplicationPolicy
  def index?
    return unbanned? if record.blank?
    (unbanned? && record == user) || user.is_admin?
  end

  def create?
    return unbanned? if record.blank?
    unbanned? && record == user
  end

  def update?
    return unbanned? if record.blank?
    unbanned? && record == user
  end

  def destroy?
    return unbanned? if record.blank?
    unbanned? && record == user
  end

  def permitted_attributes
    %i[hide_comments hide_forum_topics hide_forum_posts disable_messages suppress_mentions]
  end

  def permitted_attributes_for_create
    super + %i[target_id target_name]
  end

  def api_attributes
    super + %i[target_name]
  end

  def html_data_attributes
    super + %i[target_name]
  end
end
