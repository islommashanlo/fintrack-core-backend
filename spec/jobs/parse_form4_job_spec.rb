# frozen_string_literal: true

require "rails_helper"

RSpec.describe ParseForm4Job do
  let(:accession_no) { form4_accession(:simple_purchase) }
  let!(:filing) { create(:filing, :pending, accession_no:, cik: "0001335891") }
  let(:url) { "https://www.sec.gov/Archives/edgar/data/1335891/#{accession_no}.txt" }
  let(:archive) { FilingArchive.default }

  def stub_filing(**response)
    stub_request(:get, url).to_return(**response)
  end

  it "fetches, archives, parses and ingests the filing" do
    request = stub_filing(status: 200, body: form4_submission(:simple_purchase))

    described_class.perform_now(accession_no)

    expect(request).to have_been_requested.once
    expect(filing.reload).to have_attributes(parse_status: "parsed", raw_path: archive.path_for(accession_no))
    expect(archive.read(filing.raw_path)).to eq(form4_submission(:simple_purchase))
    expect(InsiderTransaction.count).to eq(1)
    expect(ParseFailure.count).to eq(0)
  end

  it "re-processes from the archive without asking the SEC again" do
    request = stub_filing(status: 200, body: form4_submission(:simple_purchase))

    2.times { described_class.perform_now(accession_no) }

    expect(request).to have_been_requested.once
    expect(InsiderTransaction.count).to eq(1)
  end

  describe "deterministic failures go straight to parse_failures and are not retried" do
    def expect_recorded_once(pattern)
      expect(enqueued_jobs).to be_empty
      expect(ParseFailure.sole).to have_attributes(accession_no:, attempts: 1, error: pattern, resolved_at: nil)
      expect(filing.reload.parse_status).to eq("failed")
    end

    it "handles malformed XML" do
      broken = form4_submission(:simple_purchase).sub("</issuer>", "")
      request = stub_filing(status: 200, body: broken)

      expect { described_class.perform_now(accession_no) }.not_to raise_error

      expect(request).to have_been_requested.once
      expect_recorded_once(/\AForm4Parser::MalformedError: invalid XML/)
      expect(archive.read(filing.reload.raw_path)).to eq(broken)
    end

    it "handles an empty response" do
      stub_filing(status: 200, body: "")

      described_class.perform_now(accession_no)

      expect_recorded_once(/\AEdgar::Submission::MalformedError: empty submission/)
    end

    it "handles a filing the SEC does not have" do
      request = stub_filing(status: 404)

      described_class.perform_now(accession_no)

      expect(request).to have_been_requested.once
      expect_recorded_once(/\ASecClient::NotFound/)
    end

    # Regression for the July bug: this error was a data-shape problem but was retried.
    it "handles PG::CardinalityViolation" do
      stub_filing(status: 200, body: form4_submission(:simple_purchase))
      row = { filing_id: filing.id, accession_no:, insider_cik: "0001335891", owner_seq: 1,
              issuer_cik: "0001793855", security_table: "non_derivative", txn_seq: 1 }
      # Like the ingestor, write inside a transaction; the duplicate key makes Postgres raise for real.
      allow(Form4Ingestor).to receive(:call) do
        Filing.transaction do
          InsiderTransaction.upsert_all([ row, row ], unique_by: InsiderTransaction::NATURAL_KEY_INDEX)
        end
      end

      described_class.perform_now(accession_no)

      expect_recorded_once(/PG::CardinalityViolation/)
    end
  end

  it "records an unknown accession number instead of raising" do
    described_class.perform_now("0000000001-26-000001")

    expect(ParseFailure.sole).to have_attributes(accession_no: "0000000001-26-000001", error: /unknown filing/)
  end

  describe "transient failures" do
    it "retries a server error at most three times, then records the failure" do
      request = stub_filing(status: 500)

      perform_enqueued_jobs { described_class.perform_later(accession_no) }

      expect(request).to have_been_requested.times(4)
      expect(ParseFailure.sole).to have_attributes(attempts: 1, error: /\ASecClient::TransientError/)
      expect(filing.reload.parse_status).to eq("failed")
    end

    it "schedules a retry rather than failing on the first server error" do
      stub_filing(status: 500)

      described_class.perform_now(accession_no)

      expect(described_class).to have_been_enqueued.with(accession_no)
      expect(ParseFailure.count).to eq(0)
      expect(filing.reload.parse_status).to eq("pending")
    end

    it "succeeds when the SEC recovers" do
      stub_request(:get, url).to_return({ status: 500 }, { status: 200, body: form4_submission(:simple_purchase) })

      perform_enqueued_jobs { described_class.perform_later(accession_no) }

      expect(filing.reload.parse_status).to eq("parsed")
      expect(ParseFailure.count).to eq(0)
    end
  end

  it "resolves an earlier failure when the filing later parses, keeping the record" do
    stub_filing(status: 404)
    described_class.perform_now(accession_no)

    stub_filing(status: 200, body: form4_submission(:simple_purchase))
    described_class.perform_now(accession_no)

    expect(filing.reload.parse_status).to eq("parsed")
    expect(ParseFailure.sole.resolved_at).to be_present
  end
end
