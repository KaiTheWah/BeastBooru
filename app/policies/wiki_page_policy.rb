# frozen_string_literal: true

class WikiPagePolicy < ApplicationPolicy
  def show_or_new?
    index?
  end

  def update?
    unbanned? && unrestricted?
  end

  def destroy?
    user.is_admin? && unrestricted?
  end

  def revert?
    update?
  end

  def permitted_attributes
    attr = %i[body edit_reason]
    attr += %i[parent] if user.is_trusted?
    attr += %i[protection_level] if user.is_janitor?
    attr
  end

  def permitted_attributes_for_create
    super + %i[title]
  end

  def permitted_attributes_for_update
    attr = super
    attr += %i[title] if user.is_janitor?
    attr
  end

  def permitted_search_params
    super + %i[title title_matches body_matches creator_id creator_name protection_level linked_to not_linked_to]
  end

  private

  def unrestricted?
    !record.is_a?(WikiPage) || !record.is_restricted?(user)
  end
end
