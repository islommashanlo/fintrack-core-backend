# frozen_string_literal: true

class PushSubscriptionStore
  MAXIMUM = 20
  Result = Data.define(:record, :created)
  class EndpointTaken < StandardError; end
  class LimitReached < StandardError; end

  def self.register(user:, session:, values:)
    parsed = PushSubscriptionPayload.parse(values)
    digest = PushSubscriptionSecrets.digest(parsed.canonical_endpoint)
    user.with_lock do
      session = user.sessions.active.lock.find(session.id)
      PushSubscriptionPayload.invalid! if parsed.expires_at && parsed.expires_at <= Time.current
      record = PushSubscription.find_by(endpoint_digest: digest)
      raise EndpointTaken if record && record.user_id != user.id
      raise LimitReached if record.nil? && user.push_subscriptions.count >= MAXIMUM
      created = record.nil?
      changed = created || record.session_id != session.id || PushSubscriptionSecrets.decrypt(record) != parsed.payload
      record ||= user.push_subscriptions.build(endpoint_digest: digest)
      if changed
        record.assign_attributes(session:, endpoint_origin: parsed.endpoint_origin, expires_at: parsed.expires_at, consented_at: Time.current,
          encrypted_payload: PushSubscriptionSecrets.encrypt(parsed.payload, user_id: user.id, session_id: session.id, digest:))
        record.save!
      end
      Result.new(record:, created:)
    end
  rescue ActiveRecord::RecordNotUnique
    raise EndpointTaken
  end

  def self.revoke(user:, id:)
    user.with_lock { user.push_subscriptions.find(id).destroy! }
  end
end
