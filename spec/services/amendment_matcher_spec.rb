# frozen_string_literal: true

require "rails_helper"

RSpec.describe AmendmentMatcher do
  describe "with the real amendment and its original" do
    let(:original) { Filing.find_by!(accession_no: form4_accession(:amendment_original)) }
    let(:amendment) { Filing.find_by!(accession_no: form4_accession(:amendment)) }

    it "supersedes the original and deletes nothing" do
      ingest_form4(:amendment_original)
      ingest_form4(:amendment)

      expect(amendment).to have_attributes(amends_accession_no: original.accession_no, unmatched_reason: nil,
                                           superseded_by_accession_no: nil)
      expect(original.superseded_by_accession_no).to eq(amendment.accession_no)
      expect(Filing.current).to contain_exactly(amendment)
      expect(InsiderTransaction.order(:accession_no).pluck(:accession_no, :shares)).to eq(
        [ [ original.accession_no, BigDecimal("7899") ], [ amendment.accession_no, BigDecimal("7946") ] ]
      )
    end

    it "links them when the amendment is ingested first" do
      ingest_form4(:amendment)
      expect(amendment).to have_attributes(amends_accession_no: nil, unmatched_reason: be_present)

      ingest_form4(:amendment_original)

      expect(amendment.reload).to have_attributes(amends_accession_no: original.accession_no, unmatched_reason: nil)
      expect(original.reload.superseded_by_accession_no).to eq(amendment.accession_no)
    end

    it "is stable when both are ingested again" do
      2.times do
        ingest_form4(:amendment_original)
        ingest_form4(:amendment)
      end

      expect(original.superseded_by_accession_no).to eq(amendment.accession_no)
      expect(amendment.superseded_by_accession_no).to be_nil
    end
  end

  describe "the matching rules" do
    let(:owner) { "0000000456" }
    let(:shared) { { issuer_cik: "0000000123", period_of_report: Date.new(2026, 5, 11), owner_ciks: [ owner ] } }

    def original(filed_on, **overrides)
      create(:filing, form_type: "4", filed_on:, filed_at: filed_on.to_time(:utc) + 20.hours, **shared, **overrides)
    end

    def amendment(filed_on, original_date, **overrides)
      create(:filing, form_type: "4/A", filed_on:, filed_at: filed_on.to_time(:utc) + 20.hours,
                      date_of_original_submission: original_date, **shared, **overrides)
    end

    it "uses the original submission date to choose between two filings for the same period" do
      first = original(Date.new(2026, 5, 13))
      second = original(Date.new(2026, 5, 14))
      fix = amendment(Date.new(2026, 9, 30), Date.new(2026, 5, 14))

      described_class.new(fix).link

      expect(fix.reload.amends_accession_no).to eq(second.accession_no)
      expect(second.reload.superseded_by_accession_no).to eq(fix.accession_no)
      expect(first.reload.superseded_by_accession_no).to be_nil
    end

    it "refuses to guess when the date does not settle it" do
      originals = [ original(Date.new(2026, 5, 13)), original(Date.new(2026, 5, 14)) ]
      fix = amendment(Date.new(2026, 9, 30), nil)

      described_class.new(fix).link

      expect(fix.reload).to have_attributes(amends_accession_no: nil, unmatched_reason: "ambiguous_original")
      expect(originals.map { |f| f.reload.superseded_by_accession_no }).to eq([ nil, nil ])
    end

    it "falls back to issuer, owner and period when the original was filed on another date" do
      only = original(Date.new(2026, 5, 13))
      fix = amendment(Date.new(2026, 9, 30), Date.new(2026, 5, 12))

      described_class.new(fix).link

      expect(fix.reload.amends_accession_no).to eq(only.accession_no)
    end

    it "makes the newest amendment supersede the original and earlier amendments, in any order" do
      first = original(Date.new(2026, 5, 13))
      second_fix = amendment(Date.new(2026, 9, 30), Date.new(2026, 5, 13))
      first_fix = amendment(Date.new(2026, 6, 1), Date.new(2026, 5, 13))

      described_class.new(second_fix).link
      described_class.new(first_fix).link

      expect(first.reload.superseded_by_accession_no).to eq(second_fix.accession_no)
      expect(first_fix.reload.superseded_by_accession_no).to eq(second_fix.accession_no)
      expect(second_fix.reload.superseded_by_accession_no).to be_nil
      expect(Filing.count).to eq(3)
    end

    it "does not match a filing by a different owner, issuer or period" do
      original(Date.new(2026, 5, 13), owner_ciks: [ "0000000999" ])
      original(Date.new(2026, 5, 13), issuer_cik: "0000000777")
      original(Date.new(2026, 5, 13), period_of_report: Date.new(2026, 5, 10))
      fix = amendment(Date.new(2026, 9, 30), Date.new(2026, 5, 13))

      described_class.new(fix).link

      expect(fix.reload.amends_accession_no).to be_nil
      expect(Filing.where.not(superseded_by_accession_no: nil)).to be_empty
    end

    it "says whether a missing original predates the data we hold" do
      create(:filing, filed_on: Date.new(2026, 6, 1))
      early = amendment(Date.new(2026, 9, 30), Date.new(2026, 5, 13))
      recent = amendment(Date.new(2026, 9, 30), Date.new(2026, 6, 15))

      described_class.new(early).link
      described_class.new(recent).link

      expect(early.reload.unmatched_reason).to eq("original_before_coverage")
      expect(recent.reload.unmatched_reason).to eq("original_not_found")
    end
  end
end
