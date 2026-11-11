# frozen_string_literal: true

require "rails_helper"

# Invariant 1: all SEC HTTP goes through SecClient. Other providers, such as the
# OpenFIGI enrichment API, may have their own explicitly scoped adapter.
RSpec.describe "SEC HTTP boundary" do
  HTTP_CLIENT_PATTERN = /\b(Faraday|Net::HTTP|HTTParty|RestClient|Typhoeus|Excon|URI\.open|open-uri|curl)\b/
  SEC_HOST_PATTERN = /(?:www|efts)\.sec\.gov/
  EXTERNAL_CLIENT_FILES = %w[app/services/openfigi_client.rb app/services/billing/stripe_client.rb].freeze

  it "keeps SEC HTTP client code inside SecClient" do
    offenders = Rails.root.glob("{app,lib,config}/**/*.{rb,rake}").reject do |file|
      relative = file.relative_path_from(Rails.root).to_s
      relative.end_with?("app/services/sec_client.rb") || EXTERNAL_CLIENT_FILES.include?(relative)
    end.select { |file| file.read.match?(HTTP_CLIENT_PATTERN) }
                     .map { |f| f.relative_path_from(Rails.root).to_s }

    expect(offenders).to be_empty
  end

  it "keeps the external enrichment adapter away from SEC hosts" do
    EXTERNAL_CLIENT_FILES.each do |relative|
      expect(Rails.root.join(relative).read).not_to match(SEC_HOST_PATTERN)
    end
  end
end
