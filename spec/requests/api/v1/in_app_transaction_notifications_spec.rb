# frozen_string_literal: true

require "rails_helper"

RSpec.describe "In-app insider transaction notifications" do
  include ApiAccounts
  around { |example| travel_to(Time.utc(2026, 11, 12, 11)) { with_api_csrf_protection { example.run } } }
  let(:user) { create(:user, password: "password123") }
  let(:follow) { create(:follow, user:, target_key: "ACME", skip_default_alert_rule: true) }

  def pro
    allow(Billing::Entitlements).to receive(:pro?).and_call_original
    allow(Billing::Entitlements).to receive(:pro?).with(user).and_return(true)
    allow(Billing::Entitlements).to receive(:pro_user_ids).and_return(User.where(id: user.id).select(:id))
  end

  def rule(conditions: {}, **attributes)
    result = AlertRuleControl.create(user:, follow_id: follow.id,
      attributes: { channel: "in_app", event_type: "insider_transaction", active: true, conditions: TransactionAlertConditions.normalize(conditions), **attributes })
    result.rule
  end

  def source(**attributes)
    create(:filing, issuer_ticker: "ACME", filed_at: Time.current, **attributes)
  end

  def transaction(filing, **attributes)
    create(:insider_transaction, filing:, shares: 100, price: 20, **attributes)
  end

  def list(**parameters)
    get api_v1_notifications_path, params: parameters
    response.parsed_body.fetch("data")
  end

  it "enables typed transaction rules through the API without email consent and keeps Pro instant gating" do
    api_login(user)
    post api_v1_alert_rules_path, params: { follow_id: follow.id, trigger: "insider_transaction", channels: [ "in_app" ], frequency: "instant", active: true }, headers: api_headers, as: :json
    expect(response).to have_http_status(:payment_required)
    pro
    post api_v1_alert_rules_path, params: { follow_id: follow.id, trigger: "insider_transaction", channels: [ "in_app" ], frequency: "instant", active: true,
      conditions: { direction: "purchase", min_value: "1500", codes: [ "p" ], role: "officer", security_table: "non_derivative" } }, headers: api_headers, as: :json
    expect(response).to have_http_status(:created)
    expect(response.parsed_body.dig("meta", "in_app_supported_triggers")).to include("insider_transaction")
    filing = source
    matched = transaction(filing, is_officer: true)
    transaction(filing, transaction_code: "S", is_officer: true)
    transaction(filing, shares: 1, is_officer: true)
    transaction(filing, security_table: "derivative", is_officer: true)
    AlertEvaluator.call(filing)
    data = list.sole
    expect(data).to include("trigger" => "insider_transaction", "accession" => filing.accession_no, "channel" => "in_app")
    expect(data.fetch("transaction")).to include("id" => matched.id, "transaction_code" => "P")
    expect(user.notification_preference).to be_nil
    expect(AlertDelivery.count).to eq(0)
    expect(enqueued_jobs).to be_empty
    expect(WebMock).not_to have_requested(:any, /./)
  end

  it "deduplicates joint-owner copies per rule and preserves several lines in the same filing across retries" do
    pro
    api_login(user)
    target = rule(frequency: "instant")
    filing = source
    first = transaction(filing)
    transaction(filing, owner_seq: 2, insider_cik: "0000000789", txn_seq: first.txn_seq)
    second = transaction(filing)
    derivative = transaction(filing, security_table: "derivative", txn_seq: first.txn_seq)
    2.times { AlertEvaluator.call(filing) }
    expect(target.in_app_notifications.count).to eq(3)
    expect(list.map { |row| row.fetch("transaction").fetch("id") }).to match_array([ first.id, second.id, derivative.id ])
    row = target.in_app_notifications.find_by!(insider_transaction: first)
    expect do
      InAppNotification.transaction(requires_new: true) do
        InAppNotification.insert_all!([ row.attributes.except("id").merge("insider_transaction_id" => filing.insider_transactions.find_by!(owner_seq: 2).id) ])
      end
    end.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "selects a joint owner satisfying the role filter and supports a person-scoped rule" do
    pro
    api_login(user)
    target = rule(conditions: { "role" => "director" }, frequency: "instant")
    person = create(:follow, user:, target_type: "Insider", target_key: "0000000789", skip_default_alert_rule: true)
    person_rule = AlertRuleControl.create(user:, follow_id: person.id,
      attributes: { channel: "in_app", event_type: "insider_transaction", active: true, frequency: "instant" }).rule
    filing = source
    first = transaction(filing)
    joint = transaction(filing, owner_seq: 2, insider_cik: "0000000789", txn_seq: first.txn_seq, is_director: true)
    AlertEvaluator.call(filing)
    expect(target.in_app_notifications.sole.insider_transaction_id).to eq(joint.id)
    expect(person_rule.in_app_notifications.sole.insider_transaction_id).to eq(joint.id)
  end

  it "keeps missing and suspect prices unknown and supports administrative derivative conditions" do
    pro
    api_login(user)
    valued = rule(conditions: { "min_value" => 0 }, frequency: "instant")
    filing = source
    transaction(filing, price: nil)
    transaction(filing, price_suspect: true)
    known = transaction(filing, price: 0)
    AlertEvaluator.call(filing)
    expect(valued.in_app_notifications.pluck(:insider_transaction_id)).to eq([ known.id ])
    AlertRuleControl.update(user:, id: valued.id, attributes: { active: false, conditions: { "type" => "administrative", "direction" => "other", "security_table" => "derivative" } })
    AlertRuleControl.update(user:, id: valued.id, active: true)
    later = source
    gift = transaction(later, transaction_code: "G", security_table: "derivative")
    unknown = transaction(later, transaction_code: nil, security_table: "derivative")
    transaction(later)
    AlertEvaluator.call(later)
    expect(valued.in_app_notifications.where(filing: later).pluck(:insider_transaction_id)).to match_array([ gift.id, unknown.id ])
  end

  it "delays Free notifications until the local cutoff and suppresses superseded queued sources" do
    NotificationPreferences.update(user:, attributes: { time_zone: "America/New_York" })
    api_login(user)
    target = rule
    original = source
    transaction(original)
    AlertEvaluator.call(original)
    expect(list).to be_empty
    travel 1.minute
    amendment = source(form_type: "4/A", amends_accession_no: original.accession_no)
    corrected = transaction(amendment, shares: 75)
    AlertEvaluator.call(amendment)
    travel 1.hour
    PublishInAppNotificationsJob.perform_now
    expect(target.in_app_notifications.where(filing: original).sole.published_at).to be_nil
    expect(list.sole.fetch("transaction").fetch("id")).to eq(corrected.id)
    expect(user.reload.notification_preference.email_enabled?).to be(false)
  end

  it "hides superseded published transactions from lists, counts and acknowledgement but retains the stored history" do
    pro
    api_login(user)
    rule(frequency: "instant")
    original = source
    transaction(original)
    AlertEvaluator.call(original)
    old = InAppNotification.sole
    travel 1.minute
    amendment = source(form_type: "4/A", amends_accession_no: original.accession_no)
    transaction(amendment)
    AlertEvaluator.call(amendment)
    expect(list.size).to eq(1)
    get api_v1_notifications_summary_path
    expect(response.parsed_body.dig("data", "total_count")).to eq(1)
    post api_v1_notification_read_path(old), headers: api_headers, as: :json
    expect(response).to have_http_status(:not_found)
    post api_v1_notifications_read_all_path, headers: api_headers, as: :json
    expect(response.parsed_body.dig("data", "updated_count")).to eq(1)
    expect(old.reload.read_at).to be_nil
    expect(InAppNotification.count).to eq(2)
  end

  it "allows filing and transaction notices together and shares only the same trigger's logical slot with email" do
    NotificationPreferences.update(user:, attributes: { time_zone: "America/New_York" })
    api_login(user)
    transaction_rule = rule
    AlertRuleControl.create(user:, follow_id: follow.id, attributes: { channel: "in_app", active: true })
    AlertRuleControl.create(user:, follow_id: follow.id, attributes: { channel: "email", event_type: "insider_transaction" })
    expect(AlertRuleQuota.count(user)).to eq(2)
    filing = source
    transaction(filing)
    AlertEvaluator.call(filing)
    expect(InAppNotification.count).to eq(2)
    expect(transaction_rule.in_app_notifications.sole.event_type).to eq("insider_transaction")
    travel 1.hour
    PublishInAppNotificationsJob.perform_now
    expect(list.pluck("trigger")).to match_array(%w[new_filing insider_transaction])
  end

  it "rejects institutional transaction rules and does not replay pre-activation or future sources" do
    pro
    api_login(user)
    rule(frequency: "instant")
    [ source(filed_at: 1.day.ago), source(filed_at: 1.day.from_now), source(parse_status: "failed") ].each do |filing|
      transaction(filing)
      AlertEvaluator.call(filing)
    end
    expect(InAppNotification.count).to eq(0)
    fund = create(:follow, user:, target_type: "InstitutionalFiler", target_key: "0000000123", skip_default_alert_rule: true)
    post api_v1_alert_rules_path, params: { follow_id: fund.id, trigger: "insider_transaction", channels: [ "in_app" ] }, headers: api_headers, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
  end

  it "rejects mismatched source references and excludes corrupt source pointers before counting" do
    pro
    api_login(user)
    rule(frequency: "instant")
    filing = source
    transaction(filing)
    AlertEvaluator.call(filing)
    record = InAppNotification.sole
    unrelated = transaction(source)
    record.insider_transaction = unrelated
    expect(record).not_to be_valid
    record.reload.update_column(:insider_transaction_id, unrelated.id)
    expect(list).to be_empty
    get api_v1_notifications_summary_path
    expect(response.parsed_body.dig("data", "total_count")).to eq(0)
    expect do
      InAppNotification.transaction(requires_new: true) { record.update_columns(event_type: "new_filing") }
    end.to raise_error(ActiveRecord::StatementInvalid, /in_app_notification_source/)
    expect(InAppNotification.count).to eq(1)
  end

  it "keeps snapshot cursors stable when a backdated amendment arrives after the first page" do
    pro
    api_login(user)
    rule(frequency: "instant")
    travel 1.minute
    original = source
    2.times { transaction(original) }
    AlertEvaluator.call(original)
    travel 1.minute
    list(limit: 1)
    cursor = response.parsed_body.dig("meta", "next_cursor")
    travel 1.minute
    amendment = source(form_type: "4/A", amends_accession_no: original.accession_no, filed_at: 90.seconds.ago)
    transaction(amendment)
    AlertEvaluator.call(amendment)
    expect(list(limit: 1, cursor:).size).to eq(1)
    expect(response.parsed_body.dig("meta", "total_count")).to eq(2)
    expect(list.size).to eq(1)
  end
end
