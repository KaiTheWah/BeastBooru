# frozen_string_literal: true

require "test_helper"

class ForumPostsControllerTest < ActionDispatch::IntegrationTest
  context "The forum posts controller" do
    setup do
      @user = create(:user)
      @other_user = create(:user)
      @mod = create(:moderator_user)
      as(@user) do
        @forum_topic = create(:forum_topic, title: "my forum topic", original_post_attributes: { body: "alias xxx -> yyy" })
        @forum_post = @forum_topic.original_post
      end
    end

    context "with votes" do
      setup do
        as(@user) do
          @tag_alias = create(:tag_alias, forum_post: @forum_post, status: "pending")
          @forum_post.update_columns(tag_change_request_id: @tag_alias.id, tag_change_request_type: "TagAlias")
          @vote = create(:forum_post_vote, forum_post: @forum_post, score: 1)
          @forum_post.reload
        end
      end

      should "not render the vote links for the requesting user" do
        get_auth forum_topic_path(@forum_topic), @user
        assert_select "a[title='Vote up']", false
      end

      should "render the vote links" do
        get_auth forum_topic_path(@forum_topic), @mod
        assert_select "a[title='Vote up']"
      end

      should "render existing votes" do
        get_auth forum_topic_path(@forum_topic), @mod
        assert_select "li.vote-score-up"
      end

      context "after the alias is rejected" do
        setup do
          as(@mod) do
            @tag_alias.reject!
          end
          get_auth forum_topic_path(@forum_topic), @mod
        end

        should "hide the vote links" do
          assert_select "a[title='Vote up']", false
        end

        should "still render existing votes" do
          assert_select "li.vote-score-up"
        end
      end
    end

    context "index action" do
      should "list all forum posts" do
        get forum_posts_path
        assert_response :success
      end

      context "with posts in a hidden category" do
        setup do
          as(@mod) do
            @category2 = ForumCategory.create!(name: "test", can_view: @mod.level)
            @forum_topic = create(:forum_topic, category: @category2, title: "test", original_post_attributes: { body: "test" })
            @forum_post2 = @forum_topic.original_post
          end
        end

        should "only list visible posts" do
          get forum_posts_path
          assert_response :success
          assert_select "#forum-post-#{@forum_post.id}", true
          assert_select "#forum-post-#{@forum_post2.id}", false

          get forum_posts_path(format: :json)
          assert_response :success
          assert_equal([@forum_post.id], @response.parsed_body.pluck("id"))
        end
      end

      context "with search conditions" do
        should "list all matching forum posts" do
          get forum_posts_path, params: { search: { body_matches: "xxx" } }
          assert_response :success
          assert_select "#forum-post-#{@forum_post.id}"
        end

        should "list nothing for when the search matches nothing" do
          get forum_posts_path, params: { search: { body_matches: "bababa" } }
          assert_response :success
          assert_select "#forum-post-#{@forum_post.id}", false
        end

        should "list by creator id" do
          get forum_posts_path, params: { search: { creator_id: @user.id } }
          assert_response :success
          assert_select "#forum-post-#{@forum_post.id}"
        end
      end

      should "restrict access" do
        assert_access(User::Levels::ANONYMOUS) { |user| get_auth forum_posts_path, user }
      end
    end

    context "edit action" do
      should "render if the editor is the creator of the topic" do
        get_auth edit_forum_post_path(@forum_post), @user
        assert_response :success
      end

      should "render if the editor is an admin" do
        get_auth edit_forum_post_path(@forum_post), create(:admin_user)
        assert_response :success
      end

      should "fail if the editor is not the creator of the topic and is not an admin" do
        get_auth edit_forum_post_path(@forum_post), @other_user
        assert_response :forbidden
      end

      should "restrict access" do
        assert_access(User::Levels::ADMIN) { |user| get_auth edit_forum_post_path(@forum_post), user }
      end
    end

    context "new action" do
      should "render" do
        get_auth new_forum_post_path, @user, params: { forum_post: { topic_id: @forum_topic.id } }
        assert_response :success
      end

      should "restrict access" do
        assert_access(User::Levels::MEMBER) { |user| get_auth new_forum_post_path, user, params: { forum_post: { topic_id: @forum_topic.id } } }
      end
    end

    context "create action" do
      should "create a new forum post" do
        assert_difference("ForumPost.count", 1) do
          post_auth forum_posts_path, @user, params: { forum_post: { body: "xaxaxa", topic_id: @forum_topic.id } }
          assert_redirected_to(forum_topic_path(ForumPost.last.topic, page: ForumPost.last.forum_topic_page, anchor: "forum_post_#{ForumPost.last.id}"))
        end
      end

      should "not create a new forum post if topic is stale" do
        travel_to(1.year.from_now) do
          assert_no_difference("ForumPost.count") do
            post_auth forum_posts_path, @user, params: { forum_post: { body: "xaxaxa", topic_id: @forum_topic.id }, format: :json }
            assert_response :unprocessable_entity
            assert_includes(@response.parsed_body.dig("errors", "topic"), "is stale. New posts cannot be created")
          end
        end
      end

      should "still create a new forum post if topic is stale for moderators" do
        travel_to(1.year.from_now) do
          assert_difference("ForumPost.count", 1) do
            post_auth forum_posts_path, @mod, params: { forum_post: { body: "xaxaxa", topic_id: @forum_topic.id }, format: :json }
            assert_response :success
          end
        end
      end

      should "restrict access" do
        assert_access(User::Levels::MEMBER, anonymous_response: :forbidden) { |user| post_auth forum_posts_path, user, params: { forum_post: { body: "xaxaxa", topic_id: @forum_topic.id }, format: :json } }
      end
    end

    context "destroy action" do
      should "destroy the posts" do
        delete_auth forum_post_path(@forum_post), create(:admin_user)
        assert_raises(ActiveRecord::RecordNotFound) { @forum_post.reload }
        assert_redirected_to(forum_posts_path)
      end

      context "on a forum post with edit history" do
        setup do
          as(@user) do
            @forum_post.update!(body: "hi hello")
          end
        end

        should "also delete the edit history" do
          assert_difference({ "ForumPost.count" => -1, "EditHistory.count" => -2 }) do
            delete_auth forum_post_path(@forum_post), create(:admin_user)
          end
        end
      end

      context "on a forum post with an AIBUR" do
        should "work (alias)" do
          as(@user) { @ta = create(:tag_alias, forum_topic: @forum_post.topic, forum_post: @forum_post) }
          assert_equal(@forum_post.id, @ta.reload.forum_post_id)
          assert_difference({ "ForumPost.count" => -1, "TagAlias.count" => 0 }) do
            delete_auth forum_post_path(@forum_post), create(:admin_user)
          end
          assert_nil(@ta.reload.forum_post_id)
        end

        should "work (implication)" do
          as(@user) { @ti = create(:tag_implication, forum_topic: @forum_post.topic, forum_post: @forum_post) }
          assert_equal(@forum_post.id, @ti.reload.forum_post_id)
          assert_difference({ "ForumPost.count" => -1, "TagImplication.count" => 0 }) do
            delete_auth forum_post_path(@forum_post), create(:admin_user)
          end
          assert_nil(@ti.reload.forum_post_id)
        end

        should "work (bulk update request)" do
          as(@user) { @bur = create(:bulk_update_request, forum_topic: @forum_post.topic, forum_post: @forum_post) }
          @forum_post = @bur.forum_post
          assert_equal(@forum_post.id, @bur.reload.forum_post_id)
          assert_difference({ "ForumPost.count" => -1, "BulkUpdateRequest.count" => 0 }) do
            delete_auth forum_post_path(@forum_post), create(:admin_user)
          end
          assert_nil(@bur.reload.forum_post_id)
        end
      end

      should "restrict access" do
        as(create(:admin_user)) { @posts = create_list(:forum_post, User::Levels.constants.length, topic: @forum_topic) }
        assert_access(User::Levels::ADMIN, success_response: :redirect) { |user| delete_auth forum_post_path(@posts.shift), user }
      end
    end

    context "hide action" do
      should "restore the post" do
        put_auth hide_forum_post_path(@forum_post), @mod
        assert_redirected_to(forum_post_path(@forum_post))
        @forum_post.reload
        assert_equal(true, @forum_post.is_hidden?)
      end

      should "restrict access" do
        assert_access(User::Levels::MODERATOR, success_response: :redirect) { |user| put_auth hide_forum_post_path(@forum_post), user }
      end
    end

    context "unhide action" do
      setup do
        as(@mod) do
          @forum_post.hide!
        end
      end

      should "restore the post" do
        put_auth unhide_forum_post_path(@forum_post), @mod
        assert_redirected_to(forum_post_path(@forum_post))
        @forum_post.reload
        assert_equal(false, @forum_post.is_hidden?)
      end

      should "restrict access" do
        assert_access(User::Levels::MODERATOR, success_response: :redirect) { |user| put_auth unhide_forum_post_path(@forum_post), user }
      end
    end

    context "spam" do
      setup do
        SpamDetector.stubs(:enabled?).returns(true)
        stub_request(:post, %r{https://.*\.rest\.akismet\.com/(\d\.?)+/comment-check}).to_return(status: 200, body: "true")
        stub_request(:post, %r{https://.*\.rest\.akismet\.com/(\d\.?)+/submit-spam}).to_return(status: 200, body: nil)
        stub_request(:post, %r{https://.*\.rest\.akismet\.com/(\d\.?)+/submit-ham}).to_return(status: 200, body: nil)
      end

      should "mark spam forum posts as spam" do
        SpamDetector.any_instance.stubs(:spam?).returns(true)
        assert_difference("User.system.tickets.count", 1) do
          assert_difference("ForumPost.count", 1) do
            post_auth forum_posts_path, @user, params: { forum_post: { body: "abc", topic_id: @forum_topic.id } }
            @ticket = User.system.tickets.last
            @forum_post = ForumPost.last
            assert_redirected_to(forum_topic_path(@forum_topic, page: @forum_topic.last_page, anchor: "forum_post_#{@forum_post.id}"))
          end
        end
        assert_equal(@forum_post, @ticket.model)
        assert_equal("Spam.", @ticket.reason)
        assert_equal(true, @forum_post.is_spam?)
      end

      should "not mark moderator forum posts as spam" do
        # no need to stub anything, it should return false due to Trusted+ bypassing spam checks
        assert_difference({ "User.system.tickets.count" => 0, "ForumPost.count" => 1 }) do
          post_auth forum_posts_path, @mod, params: { forum_post: { body: "abc", topic_id: @forum_topic.id } }
          @ticket = User.system.tickets.last
          @forum_post = ForumPost.last
          assert_redirected_to(forum_topic_path(@forum_topic, page: @forum_topic.last_page, anchor: "forum_post_#{@forum_post.id}"))
        end
        @forum_post = ForumPost.last
        assert_equal(false, @forum_post.is_spam?)
      end

      should "auto ban spammers" do
        SpamDetector.any_instance.stubs(:spam?).returns(true)
        as(User.system) { create_list(:ticket, SpamDetector::AUTOBAN_THRESHOLD - 1, model: @forum_post, reason: "Spam.") }
        assert_difference(%w[Ban.count User.system.tickets.count ForumPost.count], 1) do
          post_auth forum_posts_path, @user, params: { forum_post: { body: "abc", topic_id: @forum_topic.id } }
          @ticket = User.system.tickets.last
          @forum_post = ForumPost.last
          assert_redirected_to(forum_topic_path(@forum_topic, page: @forum_topic.last_page, anchor: "forum_post_#{@forum_post.id}"))
        end
        assert_equal(@forum_post, @ticket.model)
        assert_equal("Spam.", @ticket.reason)
        assert_equal(true, @forum_post.is_spam?)
        assert_equal(true, @user.reload.is_banned?)
      end

      context "mark spam action" do
        should "work and report false negative" do
          SpamDetector.any_instance.expects(:spam!).times(1)
          assert_equal(false, @forum_post.reload.is_spam?)
          put_auth mark_spam_forum_post_path(@forum_post), @mod
          assert_response(:success)
          assert_equal(true, @forum_post.reload.is_spam?)
        end

        should "work and not report false negative if ticket exists" do
          SpamDetector.any_instance.expects(:spam!).never
          User.system.tickets.create!(model: @forum_post, reason: "Spam.", creator_ip_addr: "127.0.0.1")
          assert_equal(false, @forum_post.reload.is_spam?)
          put_auth mark_spam_forum_post_path(@forum_post), @mod
          assert_response(:success)
          assert_equal(true, @forum_post.reload.is_spam?)
        end

        should "restrict access" do
          SpamDetector.any_instance.stubs(:spam!).returns(true)
          assert_access(User::Levels::MODERATOR) { |user| put_auth mark_spam_forum_post_path(@forum_post), user }
        end
      end

      context "mark not spam action" do
        should "work and not report false positive" do
          SpamDetector.any_instance.expects(:ham!).never
          @forum_post.update_column(:is_spam, true)
          assert_equal(true, @forum_post.reload.is_spam?)
          put_auth mark_not_spam_forum_post_path(@forum_post), @mod
          assert_response(:success)
          assert_equal(false, @forum_post.reload.is_spam?)
        end

        should "work and report false positive if ticket exists" do
          SpamDetector.any_instance.expects(:ham!).times(1)
          User.system.tickets.create!(model: @forum_post, reason: "Spam.", creator_ip_addr: "127.0.0.1")
          @forum_post.update_column(:is_spam, true)
          assert_equal(true, @forum_post.reload.is_spam?)
          put_auth mark_not_spam_forum_post_path(@forum_post), @mod
          assert_response(:success)
          assert_equal(false, @forum_post.reload.is_spam?)
        end

        should "restrict access" do
          assert_access(User::Levels::MODERATOR) { |user| put_auth mark_not_spam_forum_post_path(@forum_post), user }
        end
      end
    end

    context "warning action" do
      should "mark warning" do
        put_auth warning_forum_post_path(@forum_post), @mod, params: { record_type: "warning" }
        assert_response :success
        assert_equal("warning", @forum_post.reload.warning_type)
        assert_equal(@mod.id, @forum_post.reload.warning_user_id)
      end

      should "mark record" do
        put_auth warning_forum_post_path(@forum_post), @mod, params: { record_type: "record" }
        assert_response :success
        assert_equal("record", @forum_post.reload.warning_type)
        assert_equal(@mod.id, @forum_post.reload.warning_user_id)
      end

      should "mark ban" do
        put_auth warning_forum_post_path(@forum_post), @mod, params: { record_type: "ban" }
        assert_response :success
        assert_equal("ban", @forum_post.reload.warning_type)
        assert_equal(@mod.id, @forum_post.reload.warning_user_id)
      end

      should "unmark" do
        as(@mod) { @forum_post.user_warned!("warning", @mod) }
        put_auth warning_forum_post_path(@forum_post), @mod, params: { record_type: "unmark" }
        assert_response :success
        assert_nil(@forum_post.reload.warning_type)
        assert_nil(@forum_post.reload.warning_user_id)
      end

      should "restrict access" do
        assert_access(User::Levels::MODERATOR) { |user| put_auth warning_forum_post_path(@forum_post), user, params: { record_type: "warning" } }
      end
    end
  end
end
