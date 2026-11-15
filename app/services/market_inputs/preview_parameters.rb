# frozen_string_literal: true

module MarketInputs
  class PreviewParameters
    class Invalid < StandardError; end
    TIMESTAMP = /\A([0-9]{4}-[0-9]{2}-[0-9]{2})T(?:[01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9](?:\.[0-9]{1,6})?(?:Z|[+-](?:[01][0-9]|2[0-3]):[0-5][0-9])\z/

    def self.normalize(parameters, now: Time.current)
      invalid! unless parameters.keys.sort == %w[as_of cusip]
      cusip, timestamp = parameters.values_at("cusip", "as_of")
      invalid! unless cusip.is_a?(String) && cusip.match?(/\A[0-9A-Z]{9}\z/) && timestamp.is_a?(String) && timestamp.bytesize <= 40
      match = TIMESTAMP.match(timestamp)
      invalid! unless match
      begin
        date = Date.iso8601(match[1], Date::GREGORIAN)
        invalid! unless date.year.between?(1, 9999)
        time = Time.iso8601(timestamp).getutc
      rescue ArgumentError
        invalid!
      end
      invalid! unless time.year.between?(1, 9999)
      invalid! if time > now
      { cusip:, as_of: time }
    end

    def self.invalid!
      raise Invalid, "Expected one CUSIP and a nonfuture RFC3339 as_of timestamp"
    end
    private_class_method :invalid!
  end
end
