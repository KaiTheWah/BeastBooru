# frozen_string_literal: true

class ApplicationController < ActionController::Base
  class APIThrottled < StandardError; end
  class FeatureUnavailable < StandardError; end

  skip_forgery_protection if: -> { SessionLoader.new(request).has_api_authentication? || request.options? }
  before_action :reset_current_user
  before_action :set_current_user
  before_action :normalize_search
  before_action :api_check
  before_action :enable_cors
  before_action :check_valid_username
  after_action :reset_current_user
  layout "default"

  self.responder = ApplicationResponder

  include TitleHelper
  include DeferredPosts
  include Pundit::Authorization
  helper_method :deferred_post_ids, :deferred_posts, :search_params, :can_use_attribute?, :can_use_attributes?, :can_use_any_attribute?

  rescue_from Exception, with: :rescue_exception

  # This is raised on requests to `/blah.js`. Rails has already rendered StaticController#not_found
  # here, so calling `rescue_exception` would cause a double render error.
  rescue_from ActionController::InvalidCrossOriginRequest, with: -> {}

  def enable_cors
    response.headers["Access-Control-Allow-Origin"] = "*"
    response.headers["Access-Control-Allow-Headers"] = "Authorization"
    response.headers["Access-Control-Allow-Methods"] = "GET, HEAD, POST, PATCH, PUT, DELETE, OPTIONS"
  end

  def check_valid_username
    return if params[:controller] == "users/name_change_requests"

    if request.format.html? && CurrentUser.user.name_error
      redirect_to(new_user_name_change_request_path)
    end
  end

  protected

  def api_check
    if !CurrentUser.is_anonymous? && !request.get? && !request.head?
      throttled = CurrentUser.user.token_bucket.throttled?
      headers["X-Api-Limit"] = CurrentUser.user.token_bucket.cached_count.to_s
      raise(APIThrottled) if throttled
    end

    true
  end

  def rescue_exception(exception)
    @exception = exception

    # If InvalidAuthenticityToken was raised, CurrentUser isn't set so we have to do it here manually.
    CurrentUser.user ||= User.anonymous

    case exception
    when ProcessingError
      render_expected_error(400, exception)
    when APIThrottled
      render_expected_error(429, "Throttled: Too many requests")
    when ActiveRecord::QueryCanceled
      render_error_page(500, exception, message: "The database timed out running your query.")
    when ActionController::BadRequest, PostVersion::UndoError
      render_error_page(400, exception)
    when SessionLoader::AuthenticationFailure
      session.delete(:user_id)
      cookies.delete(:remember)
      status = 401
      if exception.is_a?(SessionLoader::BannedError)
        status = 403
        if request.format.json?
          return render(json: {
            success: false,
            message: exception.message,
            code:    nil,
            ban:     exception.try(:ban),
          }, status: status)
        end
        return redirect_to(acknowledge_bans_path(user_id: CurrentUser.user.signed_id(purpose: :acknowledge_ban))) if CurrentUser.user.ban_expired?
      end
      render_expected_error(status, exception.message)
    when ActionController::InvalidAuthenticityToken
      render_expected_error(403, "ActionController::InvalidAuthenticityToken. Did you properly authorize your request?")
    when ActiveRecord::RecordNotFound
      render404
    when ActiveSupport::MessageVerifier::InvalidSignature, Pundit::NotAuthorizedError
      access_denied
    when User::PrivilegeError
      access_denied(exception)
    when ActionController::RoutingError
      render_error_page(405, exception)
    when ActionController::UnknownFormat, ActionView::MissingTemplate
      render_unsupported_format
    when FemboyFans::Paginator::PaginationError
      render_expected_error(410, exception.message)
    when TagQuery::CountExceededError
      render_expected_error(422, exception.message)
    when FeatureUnavailable
      render_expected_error(501, "This feature isn't available")
    when PG::ConnectionBad
      render_error_page(503, exception, message: "The database is unavailable. Try again later.")
    when ActionController::UnpermittedParameters, ActionController::ParameterMissing
      render_expected_error(400, exception.message)
    when BCrypt::Errors::InvalidHash
      render_expected_error(400, "You must reset your password.")
    else
      render_error_page(500, exception)
    end
  end

  def render404
    respond_to do |fmt|
      fmt.html do
        render("static/404", formats: %i[html atom], status: 404)
      end
      fmt.json do
        render(json: { success: false, reason: "not found" }, status: 404)
      end
      fmt.any do
        render_unsupported_format
      end
    end
  end

  def render_unsupported_format
    render_expected_error(406, "#{request.format} is not a supported format for this page", format: :html)
  end

  def render_expected_error(status, message, format: request.format.symbol)
    format = :html unless format.in?(%i[html json atom])
    @message = message
    render("static/error", status: status, formats: format)
  end

  def render_error_page(status, exception, message: exception.message, format: request.format.symbol)
    @exception = exception
    @expected = status < 500
    @message = message.encode("utf-8", invalid: :replace, undef: :replace)
    @backtrace = Rails.backtrace_cleaner.clean(@exception.backtrace)
    format = :html unless format.in?(%i[html json atom])

    if !FemboyFans.config.show_backtrace?(CurrentUser.user, @exception.backtrace) && message == exception.message
      @message = "An unexpected error occurred."
    end

    FemboyFans::Logger.log(@exception, expected: @expected)
    log = ExceptionLog.add(exception, CurrentUser.id, request) unless @expected
    @log_code = log&.code
    render("static/error", status: status, formats: format)
  end

  def access_denied(exception = nil)
    previous_url = params[:url] || request.fullpath
    @message = "Access Denied: #{exception}" if exception.is_a?(String)
    @message ||= exception&.message || "Access Denied"

    respond_to do |format|
      format.html do
        if CurrentUser.is_anonymous?
          if request.get?
            redirect_to(new_session_path(url: previous_url), notice: @message)
          else
            redirect_to(new_session_path, notice: @message)
          end
        else
          render(template: "static/access_denied", status: 403)
        end
      end
      format.json do
        render(json: { success: false, reason: @message }.to_json, status: 403)
      end
    end
  rescue ActionController::UnknownFormat
    render(plain: @message, status: 403)
  end

  def set_current_user
    SessionLoader.new(request).load
    session.send(:load!) unless session.send(:loaded?)
  end

  def reset_current_user
    CurrentUser.user = nil
    CurrentUser.ip_addr = nil
    CurrentUser.safe_mode = FemboyFans.config.safe_mode?
  end

  def requires_reauthentication
    return if CurrentUser.user.is_anonymous?

    last_authenticated_at = session[:last_authenticated_at]
    if last_authenticated_at.blank? || Time.zone.parse(last_authenticated_at) < 1.hour.ago
      redirect_to(confirm_password_session_path(url: request.fullpath))
    end
  end

  def user_access_check(method)
    if !CurrentUser.user.send(method) || CurrentUser.user.is_banned? || IpBan.is_banned?(CurrentUser.ip_addr)
      access_denied
    end
  end

  User::Roles.each do |role|
    define_method("#{role}_only") do
      user_access_check("is_#{role}?")
    end
  end

  %i[can_view_staff_notes can_manage_aibur can_edit_avoid_posting_entries].each do |role|
    define_method("#{role}_only") do
      user_access_check("#{role}?")
    end
  end

  def logged_in_only
    if CurrentUser.is_anonymous?
      access_denied("Must be logged in")
    end
  end

  def pundit_user
    CurrentUser.user
  end

  def pundit_params_for(record)
    key = Pundit::PolicyFinder.new(record).param_key
    key = record if key == "symbol" && record.is_a?(Symbol)
    params.fetch(key, {})
  end

  def can_use_attribute?(object, attr)
    policy(object).can_use_attribute?(attr, params[:action])
  end

  def can_use_any_attribute?(object, *attrs)
    policy(object).can_use_any_attribute?(*attrs, action: params[:action])
  end

  alias can_use_attributes? can_use_attribute?

  # Remove blank `search` params from the url.
  #
  # /tags?search[name]=touhou&search[category]=&search[order]=
  # => /tags?search[name]=touhou
  def normalize_search
    return unless request.get? || request.head?
    params[:search] ||= ActionController::Parameters.new

    deep_reject_blank = ->(hash) do
      hash.reject { |_k, v| v.blank? || (v.is_a?(Hash) && deep_reject_blank.call(v).blank?) }
    end
    if params[:search].is_a?(ActionController::Parameters)
      nonblank_search_params = deep_reject_blank.call(params[:search])
    else
      nonblank_search_params = ActionController::Parameters.new
    end

    if nonblank_search_params != params[:search]
      params[:search] = nonblank_search_params
      redirect_to(url_for(params: params.except(:controller, :action, :index).permit!))
    end
  end

  def search_params(relation = nil)
    p = params.fetch(:search, {})
    return p.permit! if relation.nil? || p.empty?
    po = policy(relation)
    if po.respond_to?("permitted_search_params_for_#{action_name}")
      return p.permit(po.send("permitted_search_params_for_#{action_name}"))
    end
    p.permit(po.permitted_search_params)
  end

  def permit_search_params(permitted_params)
    params.fetch(:search, {}).permit(%i[id created_at updated_at] + permitted_params)
  end

  def format_json(data, **)
    ->(format) do
      format.json { render(json: data.to_json, **) }
    end
  end

  def notice(message)
    flash[:notice] = message if request.format.html?
  end

  def model_includes(params, model: nil) # rubocop:disable Lint/UnusedMethodArgument
    if params[:only] && params[:format] == "json"
      includes_array = ParameterBuilder.includes_parameters(params[:only], model_name)
    elsif params[:action] == "index"
      includes_array = default_includes(params)
    else
      includes_array = []
    end
    includes_array
  end

  def default_includes(*)
    []
  end

  def model_name
    controller_name.classify
  end
end
