# frozen_string_literal: true

module Sources
  module Bad
    class Null < Base
      def self.match?(_url)
        false
      end
    end
  end
end
