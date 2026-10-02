# frozen_string_literal: true

require "rails_helper"

# Invariant 1: all SEC HTTP goes through SecClient. Nothing else in the app may hold
# an HTTP client, so nothing else can reach the SEC around the rate limiter.
RSpec.describe "SEC HTTP boundary" do
  HTTP_CLIENT_PATTERN = /\b(Faraday|Net::HTTP|HTTParty|RestClient|Typhoeus|Excon|URI\.open|open-uri|curl)\b/

  it "keeps HTTP client code inside SecClient" do
    offenders = Rails.root.glob("{app,lib,config}/**/*.{rb,rake}").reject { |f| f.to_s.end_with?("app/services/sec_client.rb") }
                     .select { |f| f.read.match?(HTTP_CLIENT_PATTERN) }
                     .map { |f| f.relative_path_from(Rails.root).to_s }

    expect(offenders).to be_empty
  end
end
