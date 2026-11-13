# frozen_string_literal: true

module Api
  module V1
    module GoogleCallbackParameters
      private

      def google_callback_parameters
        values = read_parameters(allowed: %w[state code error error_description scope authuser prompt iss])
        require_parameters!(values, "state")
        raise InvalidParameter, "Invalid callback parameters" unless values.values.all? { |value| value.bytesize <= 4096 } &&
          (values.key?("code") != values.key?("error"))
        raise Oauth::GoogleLinking::Invalid if values["iss"] && values["iss"] != "https://accounts.google.com"
        keys = URI.decode_www_form(request.query_string).map(&:first)
        raise InvalidParameter, "Duplicate callback parameters" unless keys.uniq.length == keys.length
        values.slice("state", "code", "error").symbolize_keys
      end
    end
  end
end
