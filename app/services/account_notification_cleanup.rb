# frozen_string_literal: true

class AccountNotificationCleanup
  def self.call(user)
    batches = user.alert_digest_batches.select(:id)
    AlertDigestItem.where(alert_digest_batch_id: batches).delete_all
    AlertDigestBatch.where(user_id: user.id).delete_all
    user.alert_event_states.delete_all
    AlertDelivery.where(alert_rule_id: user.alert_rules.select(:id)).delete_all
    AlertRuleSetting.where(alert_rule_id: user.alert_rules.select(:id)).delete_all
  end
end
