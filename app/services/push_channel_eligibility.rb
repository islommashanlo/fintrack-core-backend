# frozen_string_literal: true

class PushChannelEligibility
  def self.call(user:, session:, as_of: Time.current)
    consent = user.notification_preference&.push_enabled? || false
    device = user.push_subscriptions.joins(:session)
      .where(session_id: session.id)
      .where("sessions.created_at > ?", as_of - Session::LIFETIME)
      .where("push_subscriptions.expires_at IS NULL OR push_subscriptions.expires_at > ?", as_of).exists?
    plan = PlanCatalog.limit_for(user, :instant_alerts)
    blockers = []
    blockers << "consent_required" unless consent
    blockers << "device_required" unless device
    blockers << "pro_required" unless plan
    # No caller can opt into transport before a sender has been implemented.
    blockers << "delivery_disabled"
    { consent_enabled: consent, current_session_device: device, plan_eligible: plan,
      delivery_enabled: false, eligible: false, blockers: }
  end
end
