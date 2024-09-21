# frozen_string_literal: true

FactoryBot.define do
  factory(:post_flag) do
    post
    reason_name { "corrupt" }
    is_resolved { false }
  end
end
