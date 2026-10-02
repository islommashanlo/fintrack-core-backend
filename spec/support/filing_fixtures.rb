# frozen_string_literal: true

# Real filings fetched from EDGAR on 2026-10-02, stored unmodified under
# spec/fixtures/filings/form4/<accession number>.txt.
module FilingFixtures
  FORM4 = {
    simple_purchase: "0001104659-26-112212",            # one owner, one open-market purchase
    weighted_average_purchase: "0001437749-26-031597",  # price explained by a footnote; officer and director
    multi_transaction: "0000947871-26-000912",          # five non-derivative and four derivative lines; prices missing
    joint_filers: "0001193125-26-409304",               # four reporting owners, one transaction, no ticker
    derivative_only: "0001193125-26-409380",            # six derivative lines, 10b5-1 box ticked
    amendment: "0001172508-26-000008",                  # 4/A correcting the grant below
    amendment_original: "0001172508-26-000007",
    holdings_only: "0001213900-26-105167",              # no transactions at all
    planned_sales: "0001489550-26-000015",              # sales under a 10b5-1 plan
    gift: "0001213900-26-105166"                        # code G at a reported price of 0
  }.freeze

  def form4_accession(name)
    FORM4.fetch(name)
  end

  def form4_submission(name)
    Rails.root.join("spec/fixtures/filings/form4/#{form4_accession(name)}.txt").binread
  end

  def form4_xml(name)
    Edgar::Submission.parse(form4_submission(name)).ownership_xml
  end
end

RSpec.configure do |config|
  config.include FilingFixtures
end
