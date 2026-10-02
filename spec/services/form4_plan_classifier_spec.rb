# frozen_string_literal: true

require "rails_helper"

RSpec.describe Form4PlanClassifier do
  it "extracts the adoption date from the real planned-sales fixture" do
    document = Form4Parser.parse(form4_xml(:planned_sales))
    transaction = document.transactions.first

    result = described_class.annotate(
      "plan_disclosed" => document.aff10b5_one,
      "filing_footnotes" => document.footnotes,
      "transaction_footnote_ids" => transaction.footnote_ids,
      "transaction_code" => transaction.transaction_code
    )

    expect(result).to include(
      "plan_status" => "10b5-1 plan disclosed",
      "plan_adoption_date" => Date.new(2026, 5, 19),
      "plan_termination_date" => nil,
      "transaction_code" => "S"
    )
    expect(result).not_to include("filing_footnotes", "transaction_footnote_ids", "plan_disclosed")
  end

  it "flags an explicit plan termination" do
    result = described_class.annotate(
      "plan_disclosed" => true,
      "filing_footnotes" => { "F1" => "The Rule 10b5-1 plan was terminated on June 30, 2026." },
      "transaction_footnote_ids" => %w[F1]
    )

    expect(result).to include(
      "plan_status" => "10b5-1 plan terminated",
      "plan_termination_date" => Date.new(2026, 6, 30)
    )
  end

  it "flags an explicit trade outside a plan" do
    result = described_class.annotate(
      "plan_disclosed" => true,
      "filing_footnotes" => { "F1" => "These shares were sold outside a Rule 10b5-1 trading plan." },
      "transaction_footnote_ids" => "{F1}"
    )

    expect(result["plan_status"]).to eq("Outside 10b5-1 plan")
  end
end
