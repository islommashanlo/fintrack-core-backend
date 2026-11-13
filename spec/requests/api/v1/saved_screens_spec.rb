# frozen_string_literal: true

require "rails_helper"

RSpec.describe "API v1 saved screens" do
  include ApiAccounts
  around { |example| with_api_csrf_protection { example.run } }
  let(:user) { create(:user, password: "password123") }

  def grant_pro(account = user)
    allow(PlanCatalog).to receive(:for_user).and_call_original
    allow(PlanCatalog).to receive(:for_user).with(account).and_return("pro")
  end

  def screen_for(account = user, name: "Reported purchases", **attributes)
    account.saved_screens.create!(name:, entity: "companies", window_days: 90, **attributes)
  end

  def create_screen(name: "Reported purchases", definition: { entity: "companies" }, **extra)
    post api_v1_saved_screens_path, params: { name:, definition:, **extra }, headers: api_headers, as: :json
  end

  it "requires authentication, CSRF and a trusted request origin" do
    get api_v1_saved_screens_path
    expect(response).to have_http_status(:unauthorized)
    grant_pro
    api_login(user)
    post api_v1_saved_screens_path, params: { name: "Example", definition: { entity: "funds" } }, as: :json
    expect(response).to have_http_status(:forbidden)
    post api_v1_saved_screens_path, params: { name: "Example", definition: { entity: "funds" } },
      headers: api_headers.merge("Origin" => "https://untrusted.example"), as: :json
    expect(response).to have_http_status(:forbidden)
    expect(SavedScreen.count).to eq(0)
  end

  it "gates every route using the server catalog and retains data after a downgrade" do
    screen = screen_for
    api_login(user)
    [ [ :get, api_v1_saved_screens_path, {} ], [ :get, api_v1_saved_screen_path(screen), {} ],
      [ :post, api_v1_saved_screens_path, { name: "Example", definition: { entity: "funds" }, plan: "pro" } ],
      [ :patch, api_v1_saved_screen_path(screen), { name: "Renamed" } ], [ :delete, api_v1_saved_screen_path(screen), {} ] ].each do |method, path, values|
      public_send(method, path, params: values, headers: api_headers, as: :json)
      expect(response).to have_http_status(:payment_required)
      expect(response.parsed_body).to eq("code" => "PRO_REQUIRED", "feature" => "saved_screens", "limit" => 0)
      expect(response.headers["Cache-Control"]).to eq("no-store")
    end
    expect(screen.reload.name).to eq("Reported purchases")
    grant_pro
    get api_v1_saved_screen_path(screen)
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("data", "name")).to eq("Reported purchases")
  end

  it "creates a normalized definition that can run unchanged through the existing screener" do
    grant_pro
    api_login(user)
    filing = create(:filing, filed_at: 1.day.ago)
    create(:insider_transaction, filing:, shares: 500, price: 25)
    definition = { entity: "companies", filters: [ { field: "ticker", operator: "eq", value: "exmp" },
      { field: "purchase_value", operator: "gte", value: "10000.000001" } ], sort: "-purchase_value", window_days: 30 }
    expect { create_screen(name: "  Reported purchases  ", definition:) }.to change(SavedScreen, :count).by(1)
    expect(response).to have_http_status(:created)
    body = response.parsed_body.fetch("data")
    expect(body.keys).to contain_exactly("id", "name", "definition", "created_at", "updated_at")
    expect(body.fetch("name")).to eq("Reported purchases")
    saved = body.fetch("definition")
    expect(saved).to include("entity" => "companies", "window_days" => 30, "sort" => "-purchase_value")
    expect(saved.fetch("filters")).to include(include("value" => "EXMP"), include("value" => "10000.000001"))
    expect(saved.keys).not_to include("limit", "cursor", "page")
    expect(response.headers["Cache-Control"]).to eq("no-store")
    expect do
      post api_v1_screener_run_path, params: saved, headers: api_headers, as: :json
    end.not_to change(Filing, :count)
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("data").sole.fetch("accession")).to eq(filing.accession_no)
  end

  it "does not write when entitlement expires after the initial route access check" do
    api_login(user)
    allow(PlanCatalog).to receive(:limit_for).and_call_original
    allow(PlanCatalog).to receive(:limit_for).with(user, :saved_screens).and_return(true, false)
    expect { create_screen }.not_to change(SavedScreen, :count)
    expect(response).to have_http_status(:payment_required)
  end

  it "round-trips insider and fund definitions without persisting pagination or an inapplicable window" do
    grant_pro
    api_login(user)
    [ "insiders", "funds" ].each do |entity|
      create_screen(name: "#{entity} reports", definition: { entity: })
      expect(response).to have_http_status(:created)
      definition = response.parsed_body.dig("data", "definition")
      expect(definition).to include("entity" => entity, "filters" => [], "sort" => "name")
      if entity == "funds"
        expect(definition).not_to have_key("window_days")
      else
        expect(definition.fetch("window_days")).to eq(90)
      end
      post api_v1_screener_run_path, params: definition, headers: api_headers, as: :json
      expect(response).to have_http_status(:ok)
    end
  end

  it "supports rename and complete definition replacement without stale fields" do
    grant_pro
    api_login(user)
    screen = screen_for(filters: [ { "field" => "purchase_count", "operator" => "gte", "value" => "2" } ], sort: "-purchase_count")
    patch api_v1_saved_screen_path(screen), params: { name: "Renamed" }, headers: api_headers, as: :json
    expect(response).to have_http_status(:ok)
    expect(screen.reload).to have_attributes(name: "Renamed", sort: "-purchase_count", window_days: 90)
    patch api_v1_saved_screen_path(screen), params: { definition: { entity: "funds" } }, headers: api_headers, as: :json
    expect(response).to have_http_status(:ok)
    expect(screen.reload).to have_attributes(name: "Renamed", entity: "funds", filters: [], sort: "name", window_days: nil)
    expect(response.parsed_body.dig("data", "definition")).not_to have_key("window_days")
    patch api_v1_saved_screen_path(screen), params: { definition: { entity: "insiders", window_days: 365 } }, headers: api_headers, as: :json
    expect(screen.reload).to have_attributes(entity: "insiders", window_days: 365)
    previous = screen.attributes
    patch api_v1_saved_screen_path(screen), params: { name: "Should not change", definition: { entity: "funds", window_days: 90 } }, headers: api_headers, as: :json
    expect(response).to have_http_status(:bad_request)
    expect(screen.reload.attributes).to eq(previous)
  end

  it "enforces case-insensitive names per user without changing an existing definition" do
    grant_pro
    api_login(user)
    own = screen_for
    other = create(:user, email_address: "other@example.com")
    screen_for(other)
    expect { create_screen(name: "REPORTED PURCHASES", definition: { entity: "funds" }) }.not_to change(SavedScreen, :count)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body.dig("error", "details")).to include("name")
    expect(own.reload.entity).to eq("companies")
    second = screen_for(name: "Second")
    patch api_v1_saved_screen_path(second), params: { name: "reported purchases" }, headers: api_headers, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(second.reload.name).to eq("Second")
  end

  it "never reads, updates or deletes another user's screens" do
    grant_pro
    api_login(user)
    other = create(:user, email_address: "other@example.com")
    screen = screen_for(other)
    [ [ :get, {} ], [ :patch, { name: "Changed" } ], [ :delete, {} ] ].each do |method, values|
      public_send(method, api_v1_saved_screen_path(screen), params: values, headers: api_headers, as: :json)
      expect(response).to have_http_status(:not_found)
    end
    get api_v1_saved_screens_path
    expect(response.parsed_body.fetch("data")).to eq([])
    expect(screen.reload.name).to eq("Reported purchases")
  end

  it "filters and sorts names as literal data with cursor bounds for newly inserted screens" do
    grant_pro
    api_login(user)
    first = screen_for(name: "Literal %_ A")
    second = screen_for(name: "Literal %_ B")
    screen_for(name: "Literal plain")
    screen_for(name: "Fund", entity: "funds", window_days: nil)
    get api_v1_saved_screens_path, params: { entity: "companies", q: "%_", sort: "name", limit: 1 }
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("data").pluck("id")).to eq([ first.id ])
    expect(response.parsed_body.fetch("meta")).to include("total_count" => 2, "has_more" => true)
    cursor = response.parsed_body.dig("meta", "next_cursor")
    screen_for(name: "Literal %_ C", created_at: 1.day.ago)
    get api_v1_saved_screens_path, params: { entity: "companies", q: "%_", sort: "name", limit: 1, cursor: }
    expect(response.parsed_body.fetch("data").pluck("id")).to eq([ second.id ])
    expect(response.parsed_body.fetch("meta")).to include("total_count" => 2, "has_more" => false)
    get api_v1_saved_screens_path, params: { entity: "funds", sort: "-created_at" }
    expect(response.parsed_body.fetch("data").pluck("name")).to eq([ "Fund" ])
  end

  it "binds cursors to account, filters, sort, resource and entitlement and rejects expired or tampered tokens" do
    grant_pro
    api_login(user)
    2.times { |i| screen_for(name: "Screen #{i}") }
    get api_v1_saved_screens_path, params: { limit: 1 }
    cursor = response.parsed_body.dig("meta", "next_cursor")
    [ { entity: "funds" }, { q: "Screen" }, { sort: "-name" }, { cursor: "#{cursor}x" } ].each do |values|
      get api_v1_saved_screens_path, params: { limit: 1, cursor:, **values }
      expect(response).to have_http_status(:bad_request)
    end
    get api_v1_watchlist_path, params: { limit: 1, cursor: }
    expect(response).to have_http_status(:bad_request)
    travel 25.hours do
      get api_v1_saved_screens_path, params: { limit: 1, cursor: }
      expect(response).to have_http_status(:bad_request)
    end
    allow(PlanCatalog).to receive(:for_user).with(user).and_return("free")
    get api_v1_saved_screens_path, params: { limit: 1, cursor: }
    expect(response).to have_http_status(:payment_required)
    other = create(:user, email_address: "other@example.com", password: "password123")
    grant_pro(other)
    api_login(other)
    get api_v1_saved_screens_path, params: { limit: 1, cursor: }
    expect(response).to have_http_status(:bad_request)
  end

  it "rejects invalid names, forged ownership/entitlements and pagination in definitions" do
    grant_pro
    api_login(user)
    [ { name: "" }, { name: " " }, { name: nil }, { name: [] }, { name: "x" * 101 }, { name: "Line\nbreak" },
      { user_id: user.id }, { plan: "pro" }, { limit: 2 }, { definition: nil }, { definition: [] },
      { definition: { entity: "funds", limit: 1 } }, { definition: { entity: "companies", cursor: "signed" } },
      { definition: { entity: "companies", page: {} } } ].each do |overrides|
      expect { create_screen(**overrides) }.not_to change(SavedScreen, :count)
      expect(response).to have_http_status(:bad_request)
    end
    create_screen(name: "Strong Buy")
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body.dig("error", "details")).to include("name")
    expect(SavedScreen.count).to eq(0)
  end

  it "reuses screener field/operator/type validation and preserves exact decimal strings" do
    grant_pro
    api_login(user)
    [ { entity: "unknown" }, { entity: "companies", sort: "name; DELETE FROM users" },
      { entity: "companies", filters: [ { field: "name", operator: "sql", value: "TRUE" } ] },
      { entity: "funds", filters: [ { field: "aum", operator: "gte", value: 1 } ] },
      { entity: "companies", filters: [ { field: "purchase_count", operator: "gte", value: -1 } ] } ].each do |definition|
      create_screen(definition:)
      expect(response).to have_http_status(:bad_request)
    end
    value = "9223372036854775808000.000001"
    create_screen(definition: { entity: "companies", filters: [ { field: "purchase_value", operator: "gte", value: } ] })
    expect(response).to have_http_status(:created)
    expect(SavedScreen.sole.filters.sole.fetch("value")).to eq(value)
  end

  it "rejects malformed list parameters, identifiers and empty updates" do
    grant_pro
    api_login(user)
    screen = screen_for
    [ { entity: "unknown" }, { q: "x" * 101 }, { q: "\0" }, { sort: "definition" }, { limit: 101 },
      { cursor: "x" * 8193 }, { user_id: user.id }, { entity: [] } ].each do |values|
      get api_v1_saved_screens_path, params: values
      expect(response).to have_http_status(:bad_request)
    end
    %w[0 -1 abc 9223372036854775808].each do |id|
      get api_v1_saved_screen_path(id)
      expect(response).to have_http_status(:bad_request)
    end
    patch api_v1_saved_screen_path(screen), params: {}, headers: api_headers, as: :json
    expect(response).to have_http_status(:bad_request)
    get api_v1_saved_screen_path(screen), params: { entity: "companies" }
    expect(response).to have_http_status(:bad_request)
  end

  it "deletes only the owned screen and preserves public filing data" do
    grant_pro
    api_login(user)
    screen = screen_for
    filing = create(:filing)
    delete api_v1_saved_screen_path(screen), headers: api_headers, as: :json
    expect(response).to have_http_status(:no_content)
    expect(SavedScreen.exists?(screen.id)).to be(false)
    expect(Filing.exists?(filing.id)).to be(true)
    delete api_v1_saved_screen_path(screen), headers: api_headers, as: :json
    expect(response).to have_http_status(:not_found)
  end

  it "cleans private saved screens on account deletion even after a downgrade" do
    own = screen_for
    other = create(:user, email_address: "other@example.com")
    retained = screen_for(other)
    api_login(user)
    delete api_v1_me_path, params: { current_password: "password123" }, headers: api_headers, as: :json
    expect(response).to have_http_status(:no_content)
    expect(SavedScreen.exists?(own.id)).to be(false)
    expect(SavedScreen.exists?(retained.id)).to be(true)
  end

  it "round-trips fund reported-label conditions through saved definitions" do
    grant_pro
    api_login(user)
    definition = { entity: "funds", sort: "coverage", filters: [
      { field: "coverage", operator: "eq", value: "complete" },
      { field: "report_type", operator: "in", value: %w[holdings combination] }
    ] }
    create_screen(name: "Reported cover types", definition:)
    expect(response).to have_http_status(:created)
    saved = response.parsed_body.dig("data", "definition")
    expect(saved.fetch("filters")).to eq(definition.fetch(:filters).map(&:stringify_keys))
    post api_v1_screener_run_path, params: saved, headers: api_headers, as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("data")).to eq([])
  end
end
