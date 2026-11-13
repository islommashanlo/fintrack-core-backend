# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Documented profile and list limiter failures" do
  include OpenapiResponses

  { "/companies/{ticker}" => "/api/v1/companies/EXMP",
    "/funds/{cik}" => "/api/v1/funds/0000000001",
    "/insiders/{cik}" => "/api/v1/insiders/0000000001",
    "/funds/{cik}/holdings" => "/api/v1/funds/0000000001/holdings",
    "/funds/{cik}/changes" => "/api/v1/funds/0000000001/changes",
    "/insiders/transactions" => "/api/v1/insiders/transactions",
    "/insiders/{cik}/transactions" => "/api/v1/insiders/0000000001/transactions",
    "/companies/{ticker}/insiders" => "/api/v1/companies/EXMP/insiders",
    "/funds/{cik}/history" => "/api/v1/funds/0000000001/history",
    "/companies/{ticker}/institutional" => "/api/v1/companies/EXMP/institutional",
    "/companies/{ticker}/history" => "/api/v1/companies/EXMP/history",
    "/funds" => "/api/v1/funds" }.each do |documented_path, request_path|
    it "returns a documented rate-limit response for #{documented_path}" do
      allow(ApiRateLimiter).to receive(:check!).and_raise(ApiRateLimiter::Limited.new(30))
      get request_path
      expect(response).to have_http_status(:too_many_requests)
      expect(response.headers["Retry-After"]).to eq("30")
      expect_documented_response(path: documented_path)
    end

    it "returns a documented temporary failure for #{documented_path}" do
      allow(ApiRateLimiter).to receive(:check!).and_raise(ApiRateLimiter::Unavailable, "internal limiter detail")
      get request_path
      expect(response).to have_http_status(:service_unavailable)
      expect(response.headers["Retry-After"]).to eq("1")
      expect(response.body).not_to include("internal limiter detail")
      expect_documented_response(path: documented_path)
      expect(WebMock).not_to have_requested(:any, /./)
    end
  end

  { "/funds/{cik}/holdings" => "/api/v1/funds/0000000001/holdings",
    "/funds/{cik}/changes" => "/api/v1/funds/0000000001/changes",
    "/insiders/{cik}/transactions" => "/api/v1/insiders/0000000001/transactions",
    "/companies/{ticker}/insiders" => "/api/v1/companies/EXMP/insiders",
    "/funds/{cik}/history" => "/api/v1/funds/0000000001/history",
    "/companies/{ticker}/institutional" => "/api/v1/companies/EXMP/institutional",
    "/companies/{ticker}/history" => "/api/v1/companies/EXMP/history" }.each do |documented_path, request_path|
    it "returns a documented missing-resource response for #{documented_path}" do
      get request_path
      expect(response).to have_http_status(:not_found)
      expect_documented_response(path: documented_path)
    end
  end
end
