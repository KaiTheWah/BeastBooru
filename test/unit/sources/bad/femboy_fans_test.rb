# frozen_string_literal: true

require "test_helper"

module Sources
  module Bad
    class FemboyFansTest < ActiveSupport::TestCase
      context "FemboyFans sources" do
        setup do
          @post1 = create(:post, source: "https://femboy.fan")
          @post2 = create(:post, source: "https://femboy.fan/posts/1")
          @post3 = create(:post, source: "https://femboy.fan/artists/gaokun")
        end

        should "always be bad" do
          assert_equal(true, @post1.bad_source?)
          assert_equal(true, @post2.bad_source?)
          assert_equal(true, @post3.bad_source?)
        end
      end
    end
  end
end
