# frozen_string_literal: true

class UserEventPolicy < ApplicationPolicy
  def index?
    user.is_admin?
  end

  def permitted_search_params
    super + %i[category user_id user_name ip_addr user_agent session_id]
  end
end
