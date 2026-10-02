# frozen_string_literal: true

# Pure parser for OpenFIGI v3 mapping responses. It keeps one result per input
# CUSIP, including explicit no-match results, so a failed lookup cannot be
# mistaken for a successful enrichment.
class OpenfigiResponseParser
  class MalformedError < StandardError; end

  Match = Data.define(
    :figi, :ticker, :name, :security_type, :market_sector, :exchange_code,
    :share_class_figi, :composite_figi
  )
  Result = Data.define(:cusip, :status, :matches, :error)

  def self.parse(cusips:, body:)
    new(cusips:, body:).parse
  end

  def initialize(cusips:, body:)
    @cusips = cusips
    @body = body
  end

  def parse
    payload = JSON.parse(@body)
    raise MalformedError, "mapping response must be an array" unless payload.is_a?(Array)
    raise MalformedError, "mapping response length does not match request" unless payload.length == @cusips.length

    payload.each_with_index.map do |entry, index|
      parse_result(@cusips[index], entry)
    end
  rescue JSON::ParserError => e
    raise MalformedError, "mapping response is not JSON: #{e.message}"
  end

  private

  def parse_result(cusip, entry)
    raise MalformedError, "mapping result must be an object" unless entry.is_a?(Hash)

    data = entry["data"]
    if data.is_a?(Array)
      matches = data.filter_map { |match| parse_match(match) }
      return Result.new(cusip:, status: "mapped", matches:, error: nil) if matches.any?
    end

    Result.new(cusip:, status: "unmapped", matches: [], error: entry["error"] || "No identifier found.")
  end

  def parse_match(match)
    return unless match.is_a?(Hash)

    Match.new(
      figi: value(match, "figi"),
      ticker: value(match, "ticker"),
      name: value(match, "name"),
      security_type: value(match, "securityType"),
      market_sector: value(match, "marketSector"),
      exchange_code: value(match, "exchCode"),
      share_class_figi: value(match, "shareClassFIGI"),
      composite_figi: value(match, "compositeFIGI")
    )
  end

  def value(hash, key)
    hash[key].to_s.strip.presence
  end
end
