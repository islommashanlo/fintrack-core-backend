# frozen_string_literal: true

module InstitutionalReadHelpers
  def create_13f(fund:, period: Date.new(2026, 6, 30), filed_at: Time.utc(2026, 8, 14), amendment_type: nil,
                 submission_type: amendment_type ? "13F-HR/A" : "13F-HR", **attributes)
    filing = create(:filing, cik: fund.cik, form_type: submission_type, filed_at:,
                    period_of_report: period, issuer_cik: nil, issuer_name: nil, issuer_ticker: nil)
    create(:institutional_report, institutional_filer: fund, filing:, period_of_report: period, filed_at:,
           amendment_type:, submission_type:, **attributes)
  end

  def map_security(cusip:, ticker:, figi: "BBG000000001")
    security = Security.create!(figi:, ticker:, name: "Example Company", source: "openfigi")
    CusipSecurityMapping.create!(cusip:, security:, result_seq: 0, status: "mapped",
                                 first_seen_at: Time.current, last_checked_at: Time.current)
  end
end
