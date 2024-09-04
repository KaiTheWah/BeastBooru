# frozen_string_literal: true

class UserEventPolicy < ApplicationPolicy
  def index?
    unbanned?
  end

  def permitted_search_params
    attr = super + %i[category user_id user_name ip_addr user_agent]
    attr += %i[session_id] if user.is_admin?
    attr
  end
end
