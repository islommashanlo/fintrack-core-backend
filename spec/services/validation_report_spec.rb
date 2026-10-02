# frozen_string_literal: true

require "rails_helper"

RSpec.describe ValidationReport do
  let(:now) { Time.utc(2026, 10, 2, 12, 0) }

  def report
    described_class.new(now:)
  end

  def levels
    report.checks.map(&:level).tally
  end

  def check_titled(pattern)
    report.checks.find { |c| c.title.match?(pattern) } || raise("no check matching #{pattern.inspect}")
  end

  it "passes cleanly on the real fixtures" do
    FilingFixtures::FORM4.each_key { |name| ingest_form4(name).update!(raw_path: "x/26/#{form4_accession(name)}.txt") }

    expect(report).not_to be_failed
    expect(levels.fetch(:fail, 0)).to eq(0)
    expect(check_titled(/Form 4 filings/).title).to include("10 Form 4 filings (10 parsed, 0 pending, 0 failed)", "26 transaction rows")
    expect(check_titled(/amendment/).level).to eq(:pass)
    expect(check_titled(/report no transactions/).title).to start_with("1 parsed filings")
  end

  it "explains every warning" do
    filing = create(:filing, raw_path: "x")
    create(:insider_transaction, filing:, transaction_code: nil)
    create(:insider_transaction, filing:, transaction_code: "S", price: nil)
    create(:insider_transaction, filing:, price: 90_000, price_suspect: true, price_suspect_reason: "over_50k_per_share")
    create(:filing, raw_path: "x", form_type: "4/A", unmatched_reason: "original_before_coverage")
    create(:filing, :pending, created_at: now - 2.hours)
    ParseFailure.record!("0000000001-26-000001", Form4Parser::MalformedError.new("invalid XML"))
    200.times { create(:filing, raw_path: "x") } # keeps one failure under the 1% limit

    warnings = report.checks.select { |c| c.level == :warn }

    expect(warnings.map(&:title)).to contain_exactly(
      a_string_matching(/1 unresolved parse failures \(0\.\d+% of filings\)/),
      "1 filings pending for over an hour (0 for over a day)",
      "1 rows flagged price_suspect",
      "1 open-market (P/S) rows have no price",
      "1 rows have no transaction code",
      "1 amendments have no matched original"
    )
    expect(warnings.map(&:detail)).to all(be_present)
    expect(check_titled(/unresolved parse failures/).detail).to include("Form4Parser::MalformedError: 1")
    expect(check_titled(/price_suspect/).detail).to include("over_50k_per_share: 1")
    expect(report).not_to be_failed
  end

  describe "failures" do
    it "fails when parse failures exceed one percent of filings" do
      create_list(:filing, 9, raw_path: "x")
      ParseFailure.record!("0000000001-26-000001", "boom")

      expect(check_titled(/unresolved parse failures/).level).to eq(:fail)
      expect(report).to be_failed
    end

    it "fails when a parsed filing lacks its acceptance time or archived copy" do
      create(:filing, filed_at: nil, raw_path: "x")
      create(:filing, raw_path: nil)

      expect(check_titled(/no filed_at/).level).to eq(:fail)
      expect(check_titled(/no raw_path/).level).to eq(:fail)
    end

    it "fails when an implausible price is not flagged" do
      create(:insider_transaction, filing: create(:filing, raw_path: "x"), price: 75_000, price_suspect: false)

      expect(check_titled(/are not flagged/).level).to eq(:fail)
    end

    it "fails when a filing is superseded by one we do not hold" do
      create(:filing, raw_path: "x", superseded_by_accession_no: "0000000009-26-000009")

      expect(check_titled(/not in the database/).level).to eq(:fail)
    end

    it "fails on a failed backfill day and on filings pending for over a day" do
      BackfillRun.create!(day: Date.new(2026, 9, 29), status: "failed", error: "SecClient::TransientError: 500")
      create(:filing, :pending, created_at: now - 2.days)

      expect(check_titled(/backfill days failed/).level).to eq(:fail)
      expect(check_titled(/pending for over an hour/).level).to eq(:fail)
    end
  end

  describe "backfill coverage" do
    it "warns about weekdays with no run and ignores weekends" do
      [ Date.new(2026, 9, 24), Date.new(2026, 9, 25), Date.new(2026, 9, 30) ].each do |day|
        BackfillRun.create!(day:, status: "done")
      end

      gap = check_titled(/weekdays between/)

      # Sat 26 and Sun 27 are not counted; Mon 28 and Tue 29 are.
      expect(gap.level).to eq(:warn)
      expect(gap.title).to include("2 weekdays", "2026-09-28, 2026-09-29")
    end

    it "explains backfilled filings dated outside the backfilled range" do
      BackfillRun.create!(day: Date.new(2026, 9, 30), status: "done")
      create(:filing, raw_path: "x", source: "daily_index", filed_on: Date.new(2026, 5, 5))
      create(:filing, raw_path: "x", source: "daily_index", filed_on: Date.new(2026, 9, 30))
      create(:filing, raw_path: "x", source: "efts", filed_on: Date.new(2026, 10, 1))

      stray = check_titled(/dated outside/)

      expect(stray.level).to eq(:warn)
      expect(stray.title).to start_with("1 backfilled filings")
      expect(stray.detail).to include("disseminated that day")
    end
  end
end
