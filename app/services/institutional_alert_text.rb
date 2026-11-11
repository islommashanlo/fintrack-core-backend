# frozen_string_literal: true

class InstitutionalAlertText
  def self.render(snapshot)
    kind = Api::V1::PositionChangeSerializer::CHANGE_TYPES.fetch(snapshot.change_type)
    key = [ snapshot.cusip, snapshot.put_call, snapshot.share_type ].compact.join(" / ")
    before = snapshot.shares_before&.to_s("F") || "not reported"
    after = snapshot.shares_after&.to_s("F") || "not reported"
    text = "#{snapshot.institutional_filer.name} reported holdings with a position classified as #{kind} for #{key}, comparing #{snapshot.prior_period_of_report} with #{snapshot.period_of_report} (reported quantity: #{before} to #{after})"
    text += " (reported value change $#{snapshot.value_usd_delta.to_s('F')})" if snapshot.value_usd_delta
    "#{text}."
  end
end
