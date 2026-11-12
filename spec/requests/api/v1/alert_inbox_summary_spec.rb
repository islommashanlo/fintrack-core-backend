# frozen_string_literal: true

require "rails_helper"

RSpec.describe "API v1 alert inbox summary" do
  include ApiAccounts
  around { |example| travel_to(Time.utc(2026, 11, 12, 12)) { with_api_csrf_protection { example.run } } }
  let(:user) { create(:user, password: "password123") }

  def summary
    get api_v1_alert_events_summary_path
    response.parsed_body.fetch("data")
  end

  it "requires a session and returns private zero counts without creating state" do
    get api_v1_alert_events_summary_path
    expect(response).to have_http_status(:unauthorized)
    api_login(user)
    expect(summary).to include("total_count" => 0, "unread_count" => 0, "read_count" => 0, "as_of" => Time.current.iso8601(3))
    expect(response.headers["Cache-Control"]).to include("no-store")
    expect(AlertEventState.count).to eq(0)
    expect(NotificationPreference.count).to eq(0)
    expect(enqueued_jobs).to be_empty
  end

  it "counts owned history independently of delivery status and preserves it after unfollow" do
    follow = create(:follow, user:)
    rows = %w[pending sent failed].map { |status| create(:alert_delivery, alert_rule: follow.alert_rule, status:) }
    other = create(:user, email_address: "other@example.com")
    create(:alert_delivery, alert_rule: create(:follow, user: other).alert_rule)
    api_login(user)
    expect(summary).to include("total_count" => 3, "unread_count" => 3, "read_count" => 0)
    post api_v1_alert_event_read_path(rows.first), headers: api_headers, as: :json
    expect(summary).to include("total_count" => 3, "unread_count" => 2, "read_count" => 1)
    follow.update!(removed_at: Time.current)
    expect(summary).to include("total_count" => 3, "unread_count" => 2)
    post api_v1_alert_events_read_all_path, headers: api_headers, as: :json
    expect(summary).to include("total_count" => 3, "unread_count" => 0, "read_count" => 3)
    create(:alert_delivery, alert_rule: follow.alert_rule)
    expect(summary).to include("total_count" => 4, "unread_count" => 1, "read_count" => 3)
  end

  it "excludes future rows and rejects unsupported filters" do
    rule = create(:follow, user:).alert_rule
    create(:alert_delivery, alert_rule: rule, created_at: 1.minute.from_now)
    api_login(user)
    expect(summary).to include("total_count" => 0)
    get api_v1_alert_events_summary_path, params: { user_id: user.id }
    expect(response).to have_http_status(:bad_request)
    travel 1.minute
    expect(summary).to include("total_count" => 1, "unread_count" => 1)
    expect(WebMock).not_to have_requested(:any, /./)
  end
end
