# frozen_string_literal: true

module Reports
  module_function

  LIMIT = 100

  def enabled?
    FemboyFans.config.reports_enabled?
  end

  def get(path)
    response = Faraday.new(FemboyFans.config.faraday_options.deep_merge(headers: { authorization: "Bearer #{jwt_signature(path)}" })).get("#{FemboyFans.config.reports_server_internal}#{path}")
    JSON.parse(response.body)
  end

  # Integer
  def get_post_views(post_id, date = nil)
    return 0 unless enabled?
    d = date ? date.strftime('%Y-%m-%d') : nil
    Cache.fetch("pv-#{post_id}-#{d}", expires_in: 1.minute) do
      get("/views/#{post_id}#{"?date=#{d}" if date}")["data"].to_i
    end
  end

  # Hash { "post" => 0, "count" => 0 }[]
  def get_post_views_rank(date, limit = LIMIT)
    return [] unless enabled?
    Cache.fetch("pv-rank-#{date}", expires_in: 1.minute) do
      get("/views/rank?date=#{date.strftime('%Y-%m-%d')}&limit=#{limit}")["data"]
    end
  end

  # Hash { "tag" => "name", "count" => 0 }[]
  def get_post_searches_rank(date, limit = LIMIT)
    return [] unless enabled?
    Cache.fetch("ps-rank-#{date}", expires_in: 1.minute) do
      get("/searches/rank?date=#{date.strftime('%Y-%m-%d')}&limit=#{limit}")["data"]
    end
  end

  # Hash { "tag" => "name", "count" => 0 }[]
  def get_missed_searches_rank(limit = LIMIT)
    return [] unless enabled?
    Cache.fetch("ms-rank", expires_in: 1.minute) do
      get("/searches/missed/rank?limit=#{limit}")["data"]
    end
  end

  # Hash { post_id => count }
  def get_bulk_post_views(post_ids, date = nil)
    return {} unless enabled?
    d = date ? date.strftime('%Y-%m-%d') : nil
    post_ids.each_slice(100).flat_map do |ids|
      get("/views/bulk?posts=#{ids.join(",")}#{"&date=#{d}" if date}")["data"]
    end.compact_blank.map { |x| [x["post"], x["count"]] }.to_h
  end

  def jwt_signature(url)
    JWT.encode({
     "iss": "FemboyFans",
     "iat": Time.now.to_i,
     "exp": 1.minute.from_now.to_i,
     "aud": "Reports",
     "sub": url.split("?").first,
   }, FemboyFans.config.report_key, "HS256")
  end
end
