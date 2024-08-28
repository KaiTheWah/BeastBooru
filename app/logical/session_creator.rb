# frozen_string_literal: true

class SessionCreator
  attr_reader :session, :cookies, :name, :password, :ip_addr, :remember, :secure, :request

  def initialize(session, cookies, name, password, ip_addr, request, remember: false, secure: false) # rubocop:disable Metrics/ParameterLists
    @session = session
    @cookies = cookies
    @name = name
    @password = password
    @ip_addr = ip_addr
    @remember = remember
    @secure = secure
    @request = request
  end

  def authenticate
    user = User.find_by_normalized_name(name)
    if User.authenticate(name, password)
      session[:user_id] = user.id
      session[:last_authenticated_at] = Time.now.utc.to_s
      session[:ph] = user.password_token
      unless user.is_banned?
        UserEvent.create_from_request!(user, :login, request)
        user.update_column(:last_ip_addr, ip_addr)
      end

      if remember
        verifier = ActiveSupport::MessageVerifier.new(FemboyFans.config.remember_key, serializer: JSON, digest: "SHA256")
        cookies.encrypted[:remember] = { value: verifier.generate("#{user.id}:#{user.password_token}", purpose: "rbr", expires_in: 14.days), expires: Time.now + 14.days, httponly: true, same_site: :lax, secure: Rails.env.production? }
      end
      return true
    end
    UserEvent.create_from_request!(user, :failed_login, request) if user.present?
    false
  end
end
