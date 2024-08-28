# frozen_string_literal: true

class UserSession < ApplicationRecord
  module SearchMethods
    def visible(user)
      if user.is_admin?
        all
      else
        none
      end
    end

    def search(params)
      q = super
      q = q.attribute_matches(:session_id, params[:session_id])
      q = q.attribute_matches(:user_agent, params[:user_agent])
      if params[:ip_addr].present?
        q = q.where("ip_addr <<= ?", params[:ip_addr])
      end
      q.apply_basic_order(params)
    end
  end
end
