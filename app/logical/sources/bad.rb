# frozen_string_literal: true

module Sources
  module Bad
    def self.all
      constants.reject { |name| name == :Base || name.to_s.include?("Test") }.map { |name| const_get(name) }
    end

    def self.find(url, default: Bad::Null)
      begin
        uri = Addressable::URI.heuristic_parse(url)
      rescue StandardError
        return default
      end
      all.find { |bad| bad.match?(uri) } || default
    end

    def self.has_bad_source?(sources)
      groups = sources.map { |source| [find(source), source] }.group_by(&:first).map { |k, v| [k, v.map(&:last)] }
      groups.each do |handler, list|
        return true if handler.new(list).bad?
      end
      false
    end
  end
end
