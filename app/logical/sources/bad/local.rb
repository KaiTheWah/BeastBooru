# frozen_string_literal: true

module Sources
  module Bad
    class Local < Base
      def bad?
        true
      end

      def self.match?(url)
        url.domain == FemboyFans.config.domain
      end
    end
  end
end
