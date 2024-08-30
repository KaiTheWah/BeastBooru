# frozen_string_literal: true

class FavoritePolicy < ApplicationPolicy
  def index?
    unbanned?
  end

  def clear?
    unbanned?
  end

  def api_attributes
    super + %i[post]
  end
end
