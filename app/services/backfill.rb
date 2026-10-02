# frozen_string_literal: true

# Registers every Form 4 listed in the daily index for a day, and records progress in
# backfill_runs. Safe to re-run: known filings are skipped.
class Backfill
  def initialize(index: Edgar::DailyIndex.new)
    @index = index
  end

  def run(from:, to:)
    (from..to).map { |date| run_day(date) }
  end

  # Never raises: a failed day is recorded on its backfill_runs row so a range keeps going.
  def run_day(date)
    run = BackfillRun.create_or_find_by!(day: date)
    run.update!(status: "running", started_at: Time.current, finished_at: nil, error: nil)

    if @index.available?(date)
      refs = @index.fetch(date)
      added = FilingRegistrar.register(refs, source: "daily_index")
      run.update!(status: "done", filings_found: refs.size, filings_new: added.size, finished_at: Time.current)
    else
      run.update!(status: "no_index", filings_found: 0, filings_new: 0, finished_at: Time.current)
    end

    run
  rescue StandardError => e
    raise if run.nil? # could not even record the run; do not hide that

    Rails.logger.error("Backfill for #{date} failed: #{e.class}: #{e.message}")
    run.update!(status: "failed", error: "#{e.class}: #{e.message}".truncate(2000), finished_at: Time.current)
    run
  end
end
