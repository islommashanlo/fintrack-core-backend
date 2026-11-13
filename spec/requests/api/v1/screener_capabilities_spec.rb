# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Screener capabilities" do
  include OpenapiResponses
  include ApiAccounts

  def capabilities
    get api_v1_screener_capabilities_path
    expect(response).to have_http_status(:ok)
    expect_documented_response(path: "/screener/capabilities", method: :get)
    expect(response.headers["Cache-Control"]).to eq("no-store")
    response.parsed_body.fetch("data")
  end

  it "publishes every supported entity and accepts each advertised sort and window" do
    items = capabilities
    expect(items.pluck("entity")).to contain_exactly("companies", "funds", "insiders")
    items.each do |item|
      entity = item.fetch("entity")
      item.fetch("sorts").each do |sort|
        expect(Api::V1::ScreenerParameters.normalize({ "entity" => entity, "sort" => sort }).fetch("sort")).to eq(sort)
      end
      expect(item.fetch("default_sort")).to eq("name")
      if entity == "funds"
        expect(item).to include("window_days" => [], "default_window_days" => nil)
      else
        expect(item).to include("window_days" => [ 30, 90, 365 ], "default_window_days" => 90)
        item.fetch("window_days").each do |window|
          expect(Api::V1::ScreenerParameters.normalize({ "entity" => entity, "window_days" => window }).fetch("window_days")).to eq(window.to_s)
        end
      end
    end
  end

  it "publishes the exact field/operator whitelist and enum values without SQL" do
    capabilities.each do |item|
      fields = item.fetch("fields")
      definition = Api::V1::ScreenerDefinition
      expect(fields.pluck("field")).to match_array(definition::FIELDS.fetch(item.fetch("entity")).keys)
      fields.each do |field|
        type = definition::FIELDS.fetch(item.fetch("entity")).fetch(field.fetch("field"))
        expect(field.fetch("operators")).to eq(definition::OPERATORS.fetch(type))
        expect(field.fetch("enum_values")).to eq(definition::ENUM_VALUES[type])
        field.fetch("enum_values")&.each do |value|
          normalized = Api::V1::ScreenerParameters.normalize({ "entity" => item.fetch("entity"), "filters" => [
            { "field" => field.fetch("field"), "operator" => "eq", "value" => value }
          ] })
          expect(normalized.fetch("filters").sole.fetch("value")).to eq(value)
        end
      end
    end
    funds = capabilities.find { |item| item.fetch("entity") == "funds" }
    expect(funds.fetch("sorts")).to include("coverage", "-coverage", "last_filed_at")
    expect(funds.fetch("sorts")).not_to include("report_type", "-report_type")
    expect(funds.fetch("fields").find { |field| field.fetch("field") == "report_type" })
      .to include("type" => "enum", "operators" => %w[eq not_eq in], "enum_values" => %w[holdings combination notice])
    expect(response.body).not_to match(/activity\.|LOWER\(|SELECT|user_id|accession/)
    expect(WebMock).not_to have_requested(:any, /./)
  end

  it "accepts a representative value for every advertised field and operator" do
    samples = { "text" => "Example", "cik" => "0000000001", "ticker" => "EXMP",
      "count" => 1, "decimal" => "1.25", "percentage" => "25.5",
      "date" => "2026-09-30", "boolean" => true }
    capabilities.each do |item|
      item.fetch("fields").each do |field|
        sample = field.fetch("type") == "enum" ? field.fetch("enum_values").first : samples.fetch(field.fetch("type"))
        field.fetch("operators").each do |operator|
          value = case operator
          when "is_null", "not_null" then nil
          when "in" then [ sample ]
          when "between" then [ sample, sample ]
          else sample
          end
          filter = { "field" => field.fetch("field"), "operator" => operator, "value" => value }
          expect { Api::V1::ScreenerParameters.normalize({ "entity" => item.fetch("entity"), "filters" => [ filter ] }) }
            .not_to raise_error
        end
      end
    end
  end

  it "returns the same capabilities for authenticated and anonymous clients" do
    anonymous = capabilities
    api_login(create(:user, password: "password123"))
    expect(capabilities).to eq(anonymous)
  end

  it "rejects unknown parameters and nested inputs" do
    [ { entity: "funds" }, { fields: [ "name" ] }, { plan: "pro" } ].each do |params|
      get api_v1_screener_capabilities_path, params: params
      expect(response).to have_http_status(:bad_request)
      expect_documented_response(path: "/screener/capabilities", method: :get)
    end
  end

  it "documents rate limits and limiter outages" do
    allow(ApiRateLimiter).to receive(:check!).and_raise(ApiRateLimiter::Limited.new(7))
    get api_v1_screener_capabilities_path
    expect(response).to have_http_status(:too_many_requests)
    expect_documented_response(path: "/screener/capabilities", method: :get)
    allow(ApiRateLimiter).to receive(:check!).and_raise(ApiRateLimiter::Unavailable)
    get api_v1_screener_capabilities_path
    expect(response).to have_http_status(:service_unavailable)
    expect_documented_response(path: "/screener/capabilities", method: :get)
  end
end
