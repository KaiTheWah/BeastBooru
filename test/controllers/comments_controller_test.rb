# frozen_string_literal: true

require "test_helper"

class CommentsControllerTest < ActionDispatch::IntegrationTest
  context "The comments controller" do
    setup do
      @mod = create(:moderator_user)
      @user = create(:member_user)
      CurrentUser.user = @user

      @post = create(:post)
      @comment = create(:comment, post: @post)
      as(@mod) do
        @mod_comment = create(:comment, post: @post)
      end
    end

    context "index action" do
      should "render for post" do
        get comments_path(post_id: @post.id, group_by: "post")
        assert_response :success
      end

      should "render by post" do
        get comments_path(group_by: "post")
        assert_response :success
      end

      should "render by comment" do
        get comments_path(group_by: "comment")
        assert_response :success
      end

      should "render for the poster_id search parameter" do
        get comments_path(group_by: "comment", search: { poster_id: 123 })
        assert_response :success
      end

      should "restrict access" do
        assert_access(User::Levels::ANONYMOUS) { |user| get_auth comments_path, user }
      end
    end

    context "search action" do
      should "render" do
        get search_comments_path
        assert_response :success
      end

      should "restrict access" do
        assert_access(User::Levels::ANONYMOUS) { |user| get_auth search_comments_path, user }
      end
    end

    context "show action" do
      should "render" do
        get comment_path(@comment)
        assert_response :success
      end

      should "restrict access" do
        assert_access(User::Levels::ANONYMOUS) { |user| get_auth comment_path(@comment), user }
      end
    end

    context "edit action" do
      should "render" do
        get_auth edit_comment_path(@comment), @user

        assert_response :success
      end

      should "restrict access" do
        assert_access(User::Levels::ADMIN) { |user| get_auth edit_comment_path(@comment), user }
      end
    end

    context "update action" do
      context "when updating another user's comment" do
        should "succeed if updater is a moderator" do
          put_auth comment_path(@comment.id), @user, params: { comment: { body: "abc" } }
          assert_equal("abc", @comment.reload.body)
          assert_redirected_to post_path(@comment.post)
        end

        should "fail if updater is not a moderator" do
          put_auth comment_path(@mod_comment.id), @user, params: { comment: { body: "abc" } }
          assert_not_equal("abc", @mod_comment.reload.body)
          assert_response 403
        end
      end

      context "when stickying a comment" do
        should "succeed if updater is a moderator" do
          @comment = create(:comment, creator: @mod)
          put_auth comment_path(@comment.id), @mod, params: { comment: { is_sticky: true } }
          assert_equal(true, @comment.reload.is_sticky)
          assert_redirected_to @comment.post
        end

        should "fail if updater is not a moderator" do
          put_auth comment_path(@comment.id), @user, params: { comment: { is_sticky: true } }
          assert_equal(false, @comment.reload.is_sticky)
        end
      end

      should "update the body" do
        put_auth comment_path(@comment.id), @user, params: { comment: { body: "abc" } }
        assert_equal("abc", @comment.reload.body)
        assert_redirected_to post_path(@comment.post)
      end

      should "not allow changing is_hidden" do
        put_auth comment_path(@comment.id), @user, params: { comment: { body: "herp derp", is_hidden: true } }
        assert_equal(false, @comment.is_hidden)
      end

      should "not allow changing do_not_bump_post or post_id" do
        as(@user) do
          @another_post = create(:post)
        end
        put_auth comment_path(@comment.id), @comment.creator, params: { do_not_bump_post: true, post_id: @another_post.id }
        assert_equal(false, @comment.reload.do_not_bump_post)
        assert_equal(@post.id, @comment.post_id)
      end

      should "restrict access" do
        assert_access(User::Levels::ADMIN, success_response: :redirect) { |user| put_auth comment_path(@comment), user, params: { comment: { body: "abc" } } }
      end
    end

    context "new action" do
      should "render" do
        get_auth new_comment_path, @user
        assert_response :success
      end

      should "restrict access" do
        assert_access(User::Levels::MEMBER) { |user| get_auth new_comment_path, user }
      end
    end

    context "create action" do
      should "create a comment" do
        assert_difference("Comment.count", 1) do
          post_auth comments_path, @user, params: { comment: { body: "abc", post_id: @post.id } }
        end
        comment = Comment.last
        assert_redirected_to post_path(comment.post)
      end

      should "not allow commenting on nonexistent posts" do
        assert_difference("Comment.count", 0) do
          post_auth comments_path, @user, params: { comment: { body: "abc", post_id: -1 } }
        end
        assert_redirected_to comments_path
      end

      should "restrict access" do
        assert_access(User::Levels::MEMBER, success_response: :redirect) { |user| post_auth comments_path, user, params: { comment: { body: "abc", post_id: @post.id } } }
      end
    end

    context "hide action" do
      should "mark comment as hidden" do
        put_auth hide_comment_path(@comment), @user
        assert_equal(true, @comment.reload.is_hidden)
        assert_redirected_to @comment
      end

      should "restrict access" do
        assert_access(User::Levels::MODERATOR, success_response: :redirect) { |user| put_auth hide_comment_path(@comment), user }
      end
    end

    context "unhide action" do
      setup do
        @comment.hide!
      end

      should "mark comment as unhidden if mod" do
        put_auth unhide_comment_path(@comment.id), @mod
        assert_equal(false, @comment.reload.is_hidden)
        assert_redirected_to(@comment)
      end

      should "not mark comment as unhidden if not mod" do
        put_auth unhide_comment_path(@comment.id), @user
        assert_equal(true, @comment.reload.is_hidden)
        assert_response :forbidden
      end

      should "restrict access" do
        assert_access(User::Levels::MODERATOR, success_response: :redirect) { |user| put_auth unhide_comment_path(@comment), user }
      end
    end

    context "destroy action" do
      should "work" do
        delete_auth comment_path(@comment), create(:admin_user)
        assert_raises(ActiveRecord::RecordNotFound) { @comment.reload }
      end

      context "on a comment with edit history" do
        setup do
          as(@user) do
            @comment.update!(body: "hi hello")
          end
        end

        should "also delete the edit history" do
          assert_difference({ "Comment.count" => -1, "EditHistory.count" => -2 }) do
            delete_auth comment_path(@comment), create(:admin_user)
          end
        end
      end

      should "restrict access" do
        assert_access(User::Levels::ADMIN, success_response: :redirect) { |user| delete_auth comment_path(create(:comment)), user }
      end
    end

    context "spam" do
      setup do
        SpamDetector.stubs(:enabled?).returns(true)
        stub_request(:post, %r{https://.*\.rest\.akismet\.com/(\d\.?)+/comment-check}).to_return(status: 200, body: "true")
        stub_request(:post, %r{https://.*\.rest\.akismet\.com/(\d\.?)+/submit-spam}).to_return(status: 200, body: nil)
        stub_request(:post, %r{https://.*\.rest\.akismet\.com/(\d\.?)+/submit-ham}).to_return(status: 200, body: nil)
      end

      should "mark spam comments as spam" do
        SpamDetector.any_instance.stubs(:spam?).returns(true)
        assert_difference(%w[User.system.tickets.count Comment.count], 1) do
          post_auth comments_path, @user, params: { comment: { body: "abc", post_id: @post.id } }
          assert_redirected_to(post_path(@post))
        end
        @ticket = User.system.tickets.last
        @comment = Comment.last
        assert_equal(@comment, @ticket.model)
        assert_equal("Spam.", @ticket.reason)
        assert_equal(true, @comment.is_spam?)
      end

      should "not mark moderator comments as spam" do
        # no need to stub anything, it should return false due to Trusted+ bypassing spam checks
        assert_difference({ "User.system.tickets.count" => 0, "Comment.count" => 1 }) do
          post_auth comments_path, @mod, params: { comment: { body: "abc", post_id: @post.id } }
          assert_redirected_to(post_path(@post))
        end
        @comment = Comment.last
        assert_equal(false, @comment.is_spam?)
      end

      should "auto ban spammers" do
        SpamDetector.any_instance.stubs(:spam?).returns(true)
        stub_const(SpamDetector, :AUTOBAN_THRESHOLD, 1) do
          assert_difference(%w[Ban.count User.system.tickets.count Comment.count], 1) do
            post_auth comments_path, @user, params: { comment: { body: "abc", post_id: @post.id } }
            assert_redirected_to(post_path(@post))
          end
        end
        @ticket = User.system.tickets.last
        @comment = Comment.last
        assert_equal(@comment, @ticket.model)
        assert_equal("Spam.", @ticket.reason)
        assert_equal("Automatically Banned", @ticket.response)
        assert_equal("approved", @ticket.status)
        assert_equal(true, @comment.is_spam?)
        assert_equal(true, @user.reload.is_banned?)
      end

      context "mark spam action" do
        should "work and report false negative" do
          SpamDetector.any_instance.expects(:spam!).times(1)
          assert_equal(false, @comment.reload.is_spam?)
          put_auth mark_spam_comment_path(@comment), @mod
          assert_response(:success)
          assert_equal(true, @comment.reload.is_spam?)
        end

        should "work and not report false negative if ticket exists" do
          SpamDetector.any_instance.expects(:spam!).never
          User.system.tickets.create!(model: @comment, reason: "Spam.", creator_ip_addr: "127.0.0.1")
          assert_equal(false, @comment.reload.is_spam?)
          put_auth mark_spam_comment_path(@comment), @mod
          assert_response(:success)
          assert_equal(true, @comment.reload.is_spam?)
        end

        should "restrict access" do
          SpamDetector.any_instance.stubs(:spam!).returns(true)
          assert_access(User::Levels::MODERATOR) { |user| put_auth mark_spam_comment_path(@comment), user }
        end
      end

      context "mark not spam action" do
        should "work and not report false positive" do
          SpamDetector.any_instance.expects(:ham!).never
          @comment.update_column(:is_spam, true)
          assert_equal(true, @comment.reload.is_spam?)
          put_auth mark_not_spam_comment_path(@comment), @mod
          assert_response(:success)
          assert_equal(false, @comment.reload.is_spam?)
        end

        should "work and report false positive if ticket exists" do
          SpamDetector.any_instance.expects(:ham!).times(1)
          User.system.tickets.create!(model: @comment, reason: "Spam.", creator_ip_addr: "127.0.0.1")
          @comment.update_column(:is_spam, true)
          assert_equal(true, @comment.reload.is_spam?)
          put_auth mark_not_spam_comment_path(@comment), @mod
          assert_response(:success)
          assert_equal(false, @comment.reload.is_spam?)
        end

        should "restrict access" do
          assert_access(User::Levels::MODERATOR) { |user| put_auth mark_not_spam_comment_path(@comment), user }
        end
      end
    end

    context "warning action" do
      should "mark warning" do
        put_auth warning_comment_path(@comment), @mod, params: { record_type: "warning" }
        assert_response :success
        assert_equal("warning", @comment.reload.warning_type)
        assert_equal(@mod.id, @comment.reload.warning_user_id)
      end

      should "mark record" do
        put_auth warning_comment_path(@comment), @mod, params: { record_type: "record" }
        assert_response :success
        assert_equal("record", @comment.reload.warning_type)
        assert_equal(@mod.id, @comment.reload.warning_user_id)
      end

      should "mark ban" do
        put_auth warning_comment_path(@comment), @mod, params: { record_type: "ban" }
        assert_response :success
        assert_equal("ban", @comment.reload.warning_type)
        assert_equal(@mod.id, @comment.reload.warning_user_id)
      end

      should "unmark" do
        @comment.user_warned!("warning", @mod)
        put_auth warning_comment_path(@comment), @mod, params: { record_type: "unmark" }
        assert_response :success
        assert_nil(@comment.reload.warning_type)
        assert_nil(@comment.reload.warning_user_id)
      end

      should "restrict access" do
        assert_access(User::Levels::MODERATOR) { |user| put_auth warning_comment_path(@comment), user, params: { record_type: "warning" } }
      end
    end
  end
end
