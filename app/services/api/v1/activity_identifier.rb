# frozen_string_literal: true

require "base64"

module Api
  module V1
    class ActivityIdentifier
      def self.encode(row)
        return "insider_#{row.fetch('source_id')}" if row.fetch("source") == "insider"

        payload = { "v" => 1, "fund_id" => row.fetch("fund_id"), "period" => row.fetch("period_of_report").iso8601,
                    "reports" => row.fetch("context_report_ids"), "key" => row.fetch("event_key") }
        token = verifier.generate(payload, purpose: "institutional_activity")
        "institutional_#{Base64.urlsafe_encode64(token, padding: false)}"
      end

      def self.decode(value)
        raise ActiveRecord::RecordNotFound if value.bytesize > 8192
        return { "source" => "insider", "id" => value.delete_prefix("insider_").to_i } if value.match?(/\Ainsider_[1-9]\d*\z/)
        raise ActiveRecord::RecordNotFound unless value.start_with?("institutional_")

        payload = verifier.verified(Base64.urlsafe_decode64(value.delete_prefix("institutional_")), purpose: "institutional_activity")
        raise ActiveRecord::RecordNotFound unless payload.is_a?(Hash) && payload["v"] == 1

        payload.merge("source" => "institutional")
      rescue ArgumentError, ActiveSupport::MessageVerifier::InvalidSignature
        raise ActiveRecord::RecordNotFound
      end

      def self.verifier
        Rails.application.message_verifier("api.v1.activity_identifiers")
      end
      private_class_method :verifier
    end
  end
end
