# frozen_string_literal: true

class UserSessionPolicy < ApplicationPolicy
  def index?
    user.is_admin?
  end

  def permitted_search_params
    super + %i[session_id user_agent ip_addr]
  end
end
