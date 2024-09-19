# frozen_string_literal: true

module Sources
  module Bad
    class FemboyFans < Base
      DOMAINS = %w[femboy.fan].freeze

      def bad?
        true
      end

      def self.match?(url)
        DOMAINS.include?(url.domain)
      end
    end
  end
end
