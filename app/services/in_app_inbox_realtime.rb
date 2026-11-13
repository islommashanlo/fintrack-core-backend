# frozen_string_literal: true

class InAppInboxRealtime
  HINT = { type: "inbox_changed", version: 1 }.freeze

  def self.enabled?
    ENV["IN_APP_REALTIME"] == "on"
  end

  def self.stream(user_id)
    "in_app_inbox:#{user_id}"
  end

  def self.after_commit(user_ids)
    return unless enabled? && user_ids.any?

    ActiveRecord.after_all_transactions_commit do
      next unless enabled?

      user_ids.uniq.each do |user_id|
        ActionCable.server.broadcast(stream(user_id), HINT)
      rescue ActiveRecord::ActiveRecordError, PG::Error => error
        # Hints are best effort. REST reads recover missed updates after a
        # committed write; a transport outage must not undo or retry that write.
        Rails.logger.warn("In-app inbox hint failed: #{error.class}")
      end
    end
  end
end
