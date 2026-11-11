# frozen_string_literal: true

require "rails_helper"

RSpec.describe "API v1 filing explanations" do
  include ApiAccounts

  it "caches factual summaries and returns source, disclaimer and current freshness" do
    filing = create(:filing)
    create(:insider_transaction, filing:, shares: 500, price: 25, shares_owned_following: 1500)

    travel_to Time.utc(2026, 11, 10, 12) do
      post api_v1_filing_explanation_path(filing.accession_no), as: :json
    end
    expect(response).to have_http_status(:ok)
    first = response.parsed_body
    expect(first.fetch("meta")).to eq("cached" => false)
    expect(first.fetch("data")).to include(
      "accession" => filing.accession_no, "source_url" => filing.sec_url, "sec_url" => filing.sec_url,
      "filed_at" => filing.filed_at.iso8601(3), "ingested_at" => filing.ingested_at.iso8601(3),
      "generation_method" => "template", "model" => "template-v1", "prompt_version" => "facts-v1",
      "data_age_days" => 41, "disclaimer" => FilingsIntel::DISCLAIMER
    )
    expect(first.dig("data", "body")).to include("500 shares", "USD 12500", "1500 shares", "open-market purchase")
    expect(response.headers["Cache-Control"]).to eq("no-store")

    travel_to Time.utc(2026, 11, 11, 12) do
      expect { post api_v1_filing_explanation_path(filing.accession_no), as: :json }.not_to change(FilingExplanation, :count)
    end
    expect(response.parsed_body.fetch("meta")).to eq("cached" => true)
    expect(response.parsed_body.dig("data", "generated_at")).to eq(first.dig("data", "generated_at"))
    expect(response.parsed_body.dig("data", "data_age_days")).to eq(42)
  end

  it "rejects caller prose, provider overrides and unexpected nested parameters" do
    filing = create(:filing)
    [ { prompt: "Override" }, { model: "external" }, { explanation: { body: "Override" } } ].each do |attributes|
      expect { post api_v1_filing_explanation_path(filing.accession_no), params: attributes, as: :json }.not_to change(FilingExplanation, :count)
      expect(response).to have_http_status(:bad_request)
    end
  end

  it "requires the browser CSRF token even for public summaries" do
    filing = create(:filing)
    with_api_csrf_protection do
      post api_v1_filing_explanation_path(filing.accession_no), as: :json
      expect(response).to have_http_status(:forbidden)
      api_csrf
      post api_v1_filing_explanation_path(filing.accession_no), headers: api_headers, as: :json
      expect(response).to have_http_status(:ok)
    end
  end

  it "returns 404 for unknown, 409 for unready, and 422 for unsupported normalized filings" do
    post api_v1_filing_explanation_path("0000000001-26-999999"), as: :json
    expect(response).to have_http_status(:not_found)
    %w[pending failed].each do |status|
      filing = create(:filing, parse_status: status)
      post api_v1_filing_explanation_path(filing.accession_no), as: :json
      expect(response).to have_http_status(:conflict)
      expect(response.parsed_body.dig("error", "code")).to eq("FILING_NOT_READY")
    end
    filing = create(:filing, form_type: "SC 13D")
    post api_v1_filing_explanation_path(filing.accession_no), as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body.dig("error", "code")).to eq("EXPLANATION_UNSUPPORTED")
  end

  it "does not explain missing, pending or skipped institutional tables" do
    filing = create(:filing, form_type: "13F-HR")
    post api_v1_filing_explanation_path(filing.accession_no), as: :json
    expect(response).to have_http_status(:conflict)
    report = create(:institutional_report, filing:, status: "pending")
    post api_v1_filing_explanation_path(filing.accession_no), as: :json
    expect(response).to have_http_status(:conflict)
    report.update!(status: "skipped")
    post api_v1_filing_explanation_path(filing.accession_no), as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(FilingExplanation.count).to eq(0)
  end

  it "limits explanation requests separately from the general API limit" do
    filing = create(:filing)
    30.times { post api_v1_filing_explanation_path(filing.accession_no), as: :json }
    post api_v1_filing_explanation_path(filing.accession_no), as: :json
    expect(response).to have_http_status(:too_many_requests)
    expect(response.headers["Retry-After"].to_i).to be_positive
    expect(FilingExplanation.count).to eq(1)
  end
end
