# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Operator endpoints" do
  def basic(user, password)
    { "Authorization" => ActionController::HttpAuthentication::Basic.encode_credentials(user, password) }
  end

  def with_credentials
    original = ENV.to_h.slice("OPS_USERNAME", "OPS_PASSWORD")
    ENV["OPS_USERNAME"] = "ops"
    ENV["OPS_PASSWORD"] = "correct horse"
    yield
  ensure
    %w[OPS_USERNAME OPS_PASSWORD].each { |key| ENV[key] = original[key] }
  end

  %w[/ops/metrics /ops/validation /sidekiq].each do |path|
    describe path do
      it "admits nobody when no credentials are configured" do
        get path
        expect(response).to have_http_status(:unauthorized)

        get path, headers: basic("", "")
        expect(response).to have_http_status(:unauthorized)
      end

      it "rejects wrong credentials and accepts the right ones" do
        with_credentials do
          get path, headers: basic("ops", "wrong")
          expect(response).to have_http_status(:unauthorized)

          get path, headers: basic("ops", "correct horse")
          expect(response).to have_http_status(:ok)
        end
      end
    end
  end

  describe "validation" do
    it "renders Form 4 and 13F checks for operators" do
      with_credentials do
        get "/ops/validation", headers: basic("ops", "correct horse")
      end

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Pipeline validation", "Form 4 checks", "13F checks", "PASS", "INFO")
    end

    it "shows failed validation checks" do
      create(:filing)
      ParseFailure.record!("0000000001-26-000001", "Form4Parser::MalformedError: invalid XML")

      with_credentials do
        get "/ops/validation", headers: basic("ops", "correct horse")
      end

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("FAIL", "unresolved parse failures")
    end
  end

  describe "the metrics" do
    let(:now) { Time.utc(2026, 10, 2, 12, 0) }

    it "reports poller lag, failure rate, queue depth and the last successful poll" do
      travel_to now do
        FilingsIntel.redis.call("SET", EdgarPoller::LAST_SUCCESS_KEY, (now - 42.seconds).iso8601)
        [ 60, 120, 600 ].each do |lag|
          create(:filing, source: "efts", filed_at: now - 1.hour, parsed_at: now - 1.hour + lag.seconds,
            ingested_at: now - 1.hour + lag.seconds)
        end
        create(:filing, source: "daily_index", filed_at: now - 30.days, parsed_at: now - 1.minute) # backfill: not counted
        create(:filing, :pending)
        ParseFailure.record!("0000000001-26-000001", "boom")
        ParseForm4Job.set(queue: "default").perform_later("0000000001-26-000002") # test adapter: not in Sidekiq

        expect(FilingArchive).not_to receive(:default)
        metrics = with_credentials do
          get "/ops/metrics", headers: basic("ops", "correct horse")
          response.parsed_body
        end

        expect(metrics).to include(
          "last_successful_poll_at" => "2026-10-02T11:59:18Z",
          "seconds_since_last_successful_poll" => 42,
          "poller_lag_seconds" => { "filings" => 3, "median" => 120, "p95" => 552 },
          "parse_failures" => { "unresolved" => 1, "failed_last_24h" => 1, "rate" => 0.2 },
          "filings" => { "pending" => 1, "parsed_last_24h" => 4 },
          "queue_depth" => { "enqueued" => 0, "retries" => 0, "scheduled" => 0, "dead" => 0 }
        )
        expect(metrics.dig("ingestion", "by_form", "4", "live_ingestion_lag_seconds")).to include("filings" => 3, "median" => 120, "p95" => 552)
        expect(metrics.dig("ingestion", "by_form", "13F-HR", "parse_failures", "rate")).to be_nil
        expect(metrics.dig("ingestion", "unclassified_parse_failures", "unresolved")).to eq(1)
        expect(metrics.dig("queues", "ready", "sec_live_form4")).to include("size" => 0, "latency_status" => "empty", "tail_age_seconds" => nil)
        expect(metrics.dig("queues", "sets", "retry")).to include("total_count" => 0, "sampled_count" => 0, "counts_complete" => true)
        expect(metrics.dig("queues", "workers_checked")).to be(false)
        expect(metrics.dig("notifications", "channels", "email")).to include("receipt_observed" => false, "failure_timestamp_recorded" => false)
        expect(metrics.dig("notifications", "channels", "in_app", "by_frequency", "instant", "completion_lag_seconds", "p95")).to be_nil
        expect(metrics.dig("health", "status")).to eq("attention")
        expect(metrics.dig("health", "checks")).to include(include("id" => "archive_files", "status" => "unknown"))
        expect(metrics.dig("archives", "filesystem_checked")).to be(false)
        expect(metrics.dig("archives", "by_form", "4")).to include("parsed_filings" => 4, "expected_documents" => 4, "missing_paths" => 4)
      end
    end

    it "copes with a poller that has never run" do
      metrics = OpsMetrics.new.to_h

      expect(metrics).to include(last_successful_poll_at: nil, seconds_since_last_successful_poll: nil)
      expect(metrics[:poller_lag_seconds]).to eq(filings: 0, median: nil, p95: nil)
      expect(metrics[:parse_failures][:rate]).to eq(0.0)
      expect(metrics.dig(:health, :status)).to eq("unknown")
    end
  end
end
