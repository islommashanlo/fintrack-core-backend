# frozen_string_literal: true

module News
  module Provider
    class NotConfigured < StandardError; end
    class Unavailable < StandardError; end
    class InvalidResponse < StandardError; end

    class Disabled
      def key
        "disabled"
      end

      def items(entity:, from:, to:)
        raise NotConfigured, "No news provider is configured"
      end
    end
  end
end
