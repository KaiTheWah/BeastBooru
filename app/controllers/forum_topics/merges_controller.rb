# frozen_string_literal: true

module ForumTopics
  class MergesController < ApplicationController
    respond_to :html, :json

    rescue_from ForumTopic::MergeError, with: ->(err) { render_expected_error(422, err.message) }

    wrap_parameters :forum_topic

    def show
      @topic = authorize(ForumTopic.find(params[:id]), :merge?)
      check_merge
      respond_with(@topic)
    end

    def create
      @topic = authorize(ForumTopic.find(params[:id]), :merge?)
      check_merge
      @target = authorize(ForumTopic.find_by(id: permitted_attributes(ForumTopic, :merge)[:target_topic_id]), :merge?, policy_class: ForumTopicPolicy)
      return render_expected_error(404, "The target topic could not be found.") if @target.blank?
      @topic.merge_into!(@target)
      respond_with(@target, notice: "Successfully merged the two topics.")
    end

    def undo
      @topic = authorize(ForumTopic.find(params[:id]), :unmerge?)
      check_unmerge
      respond_with(@topic)
    end

    def destroy
      @topic = authorize(ForumTopic.find(params[:id]), :unmerge?)
      check_unmerge
      @topic.undo_merge!
      respond_with(@topic)
    end

    private

    def check_merge
      raise(ForumTopic::MergeError, "Topic is already merged") if @topic.is_merged?
    end

    def check_unmerge
      raise(ForumTopic::MergeError, "Topic is not merged") unless @topic.is_merged?
    end
  end
end
