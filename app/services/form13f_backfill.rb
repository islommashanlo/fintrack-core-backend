# frozen_string_literal: true

# Plans and executes a 13F daily-index backfill. Planning is read-only apart from the
# SEC requests needed to enumerate daily indexes; execution is gated by the rake task.
class Form13fBackfill
  Plan = Data.define(:from, :to, :refs_by_day, :discovery_requests, :document_requests) do
    def refs
      refs_by_day.values.flatten.uniq(&:accession_no)
    end

    def request_count
      discovery_requests + document_requests
    end
  end

  def initialize(client: nil, index: nil, archive: FilingArchive.default)
    @client = client
    @index = index
    @archive = archive
  end

  def plan(from:, to:, ciks: nil)
    counter = RequestCounter.new(client)
    index = @index || Edgar::DailyIndex.new(client: counter, forms: Filing::FORM13F_TYPES)
    refs_by_day = {}

    (from..to).each do |day|
      next unless index.available?(day)

      refs_by_day[day] = index.fetch(day).select do |ref|
        Filing::FORM13F_TYPES.include?(ref.form_type) && (ciks.blank? || ciks.include?(ref.cik))
      end
    end

    refs = refs_by_day.values.flatten.uniq(&:accession_no)
    known = Filing.where(accession_no: refs.map(&:accession_no)).index_by(&:accession_no)
    document_requests = refs.sum { |ref| document_request_count(ref, known[ref.accession_no]) }

    Plan.new(
      from:, to:, refs_by_day:, discovery_requests: counter.count, document_requests:
    )
  end

  def execute(plan, value_unit:)
    needs_unit = plan.refs.any? { |ref| ref.form_type != "13F-NT" }
    raise ArgumentError, "value_unit is required for 13F holdings reports" if needs_unit && value_unit.blank?

    plan.refs_by_day.map do |day, refs|
      run_day(day, refs, value_unit:)
    end
  end

  private

  def run_day(day, refs, value_unit:)
    run = BackfillRun.create_or_find_by!(day:)
    run.update!(status: "running", started_at: Time.current, finished_at: nil, error: nil)
    added = FilingRegistrar.register(refs, source: "daily_index", value_unit:)
    run.update!(status: "done", filings_found: refs.size, filings_new: added.size, finished_at: Time.current)
    run
  rescue StandardError => e
    raise if run.nil?

    Rails.logger.error("13F backfill for #{day} failed: #{e.class}: #{e.message}")
    run.update!(status: "failed", error: "#{e.class}: #{e.message}".truncate(2000), finished_at: Time.current)
    run
  end

  def document_request_count(ref, filing)
    return 0 if parsed_and_archived?(filing)

    ref.form_type == "13F-NT" ? 2 : 3
  end

  def parsed_and_archived?(filing)
    report = filing&.institutional_report
    report&.status == "parsed" && @archive.exist?(report.cover_raw_path)
  end

  def client
    @client ||= SecClient.new(lane: :form13f)
  end

  class RequestCounter
    attr_reader :count

    def initialize(client)
      @client = client
      @count = 0
    end

    def get(url)
      @count += 1
      @client.get(url)
    end

    def get_json(url)
      @count += 1
      @client.get_json(url)
    end
  end
end
