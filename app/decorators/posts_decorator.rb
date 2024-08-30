# frozen_string_literal: true

class PostsDecorator < ApplicationDecorator
  def self.collection_decorator_class
    PaginatedDecorator
  end

  alias post object

  delegate_all

  def preview_class(options)
    klass = ["post-preview"]
    klass << "post-status-pending" if post.is_pending?
    klass << "post-status-flagged" if post.is_flagged?
    klass << "post-status-deleted" if post.is_deleted?
    klass << "post-status-has-parent" if post.parent_id
    klass << "post-status-has-children" if post.has_visible_children?
    klass << "post-rating-safe" if post.rating == "s"
    klass << "post-rating-questionable" if post.rating == "q"
    klass << "post-rating-explicit" if post.rating == "e"
    klass << "blacklistable" unless options[:no_blacklist]
    klass
  end

  def data_attributes
    { data: object.thumbnail_attributes }
  end

  def cropped_url(options)
    cropped_url = if FemboyFans.config.enable_image_cropping? && options[:show_cropped] && object.has_cropped? && !CurrentUser.user.disable_cropped_thumbnails?
                    object.crop_file_url
                  else
                    object.preview_file_url
                  end

    cropped_url = FemboyFans.config.deleted_preview_url if object.deleteblocked?
    cropped_url
  end

  def score_class(score)
    return "score-neutral" if score == 0
    score > 0 ? "score-positive" : "score-negative"
  end

  def preview_html(template, options = {})
    return "" if post.nil?

    if !options[:show_deleted] && post.is_deleted? && options[:tags] !~ /(?:status:(?:all|any|deleted))|(?:deletedby:)|(?:delreason:)/i
      return ""
    end

    if post.loginblocked? || post.safeblocked?
      return ""
    end

    article_attrs = {
      id:    "post_#{post.id}",
      class: preview_class(options).join(" "),
    }.merge(data_attributes)

    link_target = options[:link_target] || post

    link_params = {}
    if options[:tags].present?
      link_params["q"] = options[:tags]
    end
    if options[:pool_id]
      link_params["pool_id"] = options[:pool_id]
    end
    if options[:post_set_id]
      link_params["post_set_id"] = options[:post_set_id]
    end

    tooltip = "Rating: #{post.rating}\nID: #{post.id}\nDate: #{post.created_at}\nStatus: #{post.status}\nScore: #{post.score}"
    tooltip += "\nUploader: #{post.uploader_name}" if CurrentUser.user.is_janitor? || CurrentUser.user.show_post_uploader?
    if CurrentUser.user.is_janitor? && (post.is_flagged? || post.is_deleted?)
      flag = post.flags.order(id: :desc).first
      tooltip += "\nFlag Reason: #{flag&.reason}" if post.is_flagged?
      tooltip += "\nDel Reason: #{flag&.reason}" if post.is_deleted?
    end
    tooltip += "\n\n#{post.tag_string}"

    cropped_url = if FemboyFans.config.enable_image_cropping? && options[:show_cropped] && post.has_cropped? && !CurrentUser.user.disable_cropped_thumbnails?
                    post.crop_file_url
                  else
                    post.preview_file_url
                  end

    cropped_url = FemboyFans.config.deleted_preview_url if post.deleteblocked?
    preview_url = if post.deleteblocked?
                    FemboyFans.config.deleted_preview_url
                  else
                    post.preview_file_url
                  end

    alt_text = post.tag_string

    has_cropped = post.has_cropped?

    pool = options[:pool]

    similarity = options[:similarity]&.round

    size = options[:size] ? post.file_size : nil

    img_contents = template.link_to(template.polymorphic_path(link_target, link_params)) do
      template.tag.picture do
        template.concat(template.tag.source(media: "(max-width: 800px)", srcset: cropped_url))
        template.concat(template.tag.source(media: "(min-width: 800px)", srcset: preview_url))
        template.concat(template.tag.img(class: "has-cropped-#{has_cropped}", src: preview_url, title: tooltip, alt: alt_text))
      end
    end
    desc_contents = if options[:stats] || pool || similarity || size
                      template.tag.div(class: "desc") do
                        template.post_stats_section(post) if options[:stats]
                      end
                    else
                      "".html_safe
                    end

    ribbons = template.post_ribbons(post)
    # ribbons = t.render("posts/partials/index/ribbons", post: post).html_safe
    vote_buttons = template.post_vote_buttons(post)
    # vote_buttons = t.render("posts/partials/index/vote_buttons", post: post, vote: vote).html_safe
    template.tag.article(**article_attrs) do
      img_contents + desc_contents + ribbons + vote_buttons
    end
  end
end
