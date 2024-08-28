# frozen_string_literal: true

FactoryBot.define do
  factory(:user_session) do
    ip_addr { "127.0.0.1" }
    session_id { SecureRandom.hex(32) }
    user_agent { "Mozilla/5.0" }
  end
end
