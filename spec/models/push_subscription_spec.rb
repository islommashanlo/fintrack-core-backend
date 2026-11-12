# frozen_string_literal: true

require "rails_helper"

RSpec.describe PushSubscription do
  let(:user) { create(:user) }
  let(:session) { user.sessions.create! }

  it "enforces endpoint uniqueness and cleans up even when sessions are bulk-revoked" do
    row = PushSubscriptionStore.register(user:, session:, values: push_registration).record
    expect { described_class.insert_all!([ row.attributes.except("id") ]) }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "cascades bulk session revocation and binds ciphertext to its owner, session and endpoint identity" do
    row = PushSubscriptionStore.register(user:, session:, values: push_registration).record
    changed = row.dup
    changed.session_id = session.id + 1
    expect { PushSubscriptionSecrets.decrypt(changed) }.to raise_error(ActiveSupport::MessageEncryptor::InvalidMessage)
    user.sessions.delete_all
    expect(described_class.count).to eq(0)
  end
end
