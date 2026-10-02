# frozen_string_literal: true

# Health checks over the ingested data, printed by `rake validate:report`.
#
# FAIL means an invariant is broken or data is missing. WARN means something a person
# should understand; each WARN says what it means and where to look. All counting is SQL.
class ValidationReport
  Check = Data.define(:level, :title, :detail)

  FAILURE_RATE_LIMIT = 0.01
  STALE_PENDING = 1.hour
  LOST_PENDING = 24.hours

  def initialize(now: Time.current)
    @now = now
  end

  def checks
    @checks ||= [
      volume, parse_failures, pending_filings, missing_filed_at, missing_archive,
      unflagged_implausible_prices, suspect_prices, open_market_without_price, nil_codes,
      unmatched_amendments, dangling_supersedes, failed_backfill_days, stuck_backfill_days,
      uncovered_weekdays, filings_outside_backfill_window, filings_without_transactions
    ]
  end

  def failed?
    checks.any? { |check| check.level == :fail }
  end

  private

  def check(level, title, detail = nil)
    Check.new(level:, title:, detail:)
  end

  def form4
    Filing.form4
  end

  def volume
    range = form4.parsed.pick(Arel.sql("MIN(filed_at)"), Arel.sql("MAX(filed_at)"))
    span = range.compact.map { |t| t.utc.strftime("%Y-%m-%d") }.join(" to ").presence || "none yet"

    check(:info, "#{form4.count} Form 4 filings (#{form4.parsed.count} parsed, #{form4.pending.count} pending, " \
                 "#{form4.failed.count} failed); #{InsiderTransaction.count} transaction rows; filed #{span}")
  end

  def parse_failures
    unresolved = ParseFailure.unresolved.count
    total = form4.count
    return check(:pass, "No unresolved parse failures") if unresolved.zero?

    rate = unresolved.fdiv(total)
    by_class = ParseFailure.unresolved.group(Arel.sql("split_part(error, ': ', 1)")).count
    detail = "#{by_class.map { |klass, n| "#{klass}: #{n}" }.join('; ')}. See `rake diagnose:failures`. " \
             "These were not retried because they are deterministic, or they outlasted three retries."

    check(rate > FAILURE_RATE_LIMIT ? :fail : :warn,
          "#{unresolved} unresolved parse failures (#{(rate * 100).round(2)}% of filings)", detail)
  end

  def pending_filings
    stale = form4.pending.where(created_at: ...(@now - STALE_PENDING)).count
    lost = form4.pending.where(created_at: ...(@now - LOST_PENDING)).count
    return check(:pass, "No filings stuck in pending") if stale.zero?

    check(lost.positive? ? :fail : :warn, "#{stale} filings pending for over an hour (#{lost} for over a day)",
          "Either the queue is still draining or their jobs were lost. `rake pipeline:requeue_pending` queues them again.")
  end

  def missing_filed_at
    count = form4.parsed.where(filed_at: nil).count
    return check(:pass, "Every parsed filing has an acceptance time") if count.zero?

    check(:fail, "#{count} parsed filings have no filed_at", "Point-in-time queries key on filed_at.")
  end

  def missing_archive
    count = form4.parsed.where(raw_path: nil).count
    return check(:pass, "Every parsed filing has an archived raw copy recorded") if count.zero?

    check(:fail, "#{count} parsed filings have no raw_path", "Raw filings must be archived before they are parsed.")
  end

  def unflagged_implausible_prices
    count = InsiderTransaction.where(price_suspect: false).where("price > ?", PriceCheck::MAX_PLAUSIBLE_PRICE).count
    return check(:pass, "No unflagged price above $#{PriceCheck::MAX_PLAUSIBLE_PRICE} per share") if count.zero?

    check(:fail, "#{count} rows priced above $#{PriceCheck::MAX_PLAUSIBLE_PRICE} per share are not flagged",
          "They were ingested before the price check existed. Re-ingest them from the archive.")
  end

  def suspect_prices
    by_reason = InsiderTransaction.where(price_suspect: true).group(:price_suspect_reason).count
    return check(:pass, "No rows flagged price_suspect") if by_reason.empty?

    check(:warn, "#{by_reason.values.sum} rows flagged price_suspect",
          "#{by_reason.map { |reason, n| "#{reason}: #{n}" }.join('; ')}. The reported price is kept and the rows are " \
          "left out of value sums. `rake diagnose:prices` lists them; a genuine high price such as BRK.A will appear here.")
  end

  def open_market_without_price
    count = InsiderTransaction.where(transaction_code: InsiderTransaction::OPEN_MARKET_CODES, price: nil).count
    return check(:pass, "Every open-market (P/S) row has a price") if count.zero?

    check(:warn, "#{count} open-market (P/S) rows have no price",
          "The filer gave the price only in a footnote. The rows are kept and left out of value sums.")
  end

  def nil_codes
    count = InsiderTransaction.where(transaction_code: nil).count
    return check(:pass, "Every transaction has a code") if count.zero?

    check(:warn, "#{count} rows have no transaction code",
          "Stored as reported. No signal query counts them, since none can tell what kind of trade they are.")
  end

  def unmatched_amendments
    by_reason = form4.parsed.amendments.where(amends_accession_no: nil).group(:unmatched_reason).count
    return check(:pass, "Every amendment is linked to its original") if by_reason.empty?

    check(:warn, "#{by_reason.values.sum} amendments have no matched original",
          "#{by_reason.map { |reason, n| "#{reason || 'not yet evaluated'}: #{n}" }.join('; ')}. " \
          "original_before_coverage: the original was filed before the earliest day we hold. " \
          "original_not_found and ambiguous_original need a look; the amendment's own rows still count.")
  end

  def dangling_supersedes
    count = Filing.where.not(superseded_by_accession_no: nil)
                  .where("NOT EXISTS (SELECT 1 FROM filings s WHERE s.accession_no = filings.superseded_by_accession_no)")
                  .count
    return check(:pass, "Every superseded filing points at a filing we hold") if count.zero?

    check(:fail, "#{count} filings are superseded by a filing that is not in the database")
  end

  def failed_backfill_days
    days = BackfillRun.where(status: "failed").order(:day).pluck(:day)
    return check(:pass, "No failed backfill days") if days.empty?

    check(:fail, "#{days.size} backfill days failed: #{days.first(10).join(', ')}", "Re-run them with `rake backfill:run[from,to]`.")
  end

  def stuck_backfill_days
    days = BackfillRun.where(status: "running", started_at: ...(@now - STALE_PENDING)).order(:day).pluck(:day)
    return check(:pass, "No backfill day stuck in running") if days.empty?

    check(:warn, "#{days.size} backfill days have been running for over an hour: #{days.first(10).join(', ')}",
          "The process that started them probably died. Re-running the day is safe.")
  end

  def uncovered_weekdays
    first, last = BackfillRun.pick(Arel.sql("MIN(day)"), Arel.sql("MAX(day)"))
    return check(:info, "No backfill has been run") if first.nil?

    missing = BackfillRun.connection.select_values(BackfillRun.sanitize_sql([ <<~SQL, first, last ]))
      SELECT d::date
      FROM generate_series(?::date, ?::date, interval '1 day') AS d
      WHERE EXTRACT(ISODOW FROM d) < 6
        AND NOT EXISTS (SELECT 1 FROM backfill_runs r WHERE r.day = d::date)
      ORDER BY 1
    SQL
    return check(:pass, "Every weekday from #{first} to #{last} has a backfill run") if missing.empty?

    check(:warn, "#{missing.size} weekdays between #{first} and #{last} have no backfill run: #{missing.first(10).join(', ')}",
          "The backfill was run over separate ranges. Run it for these days to close the gap.")
  end

  def filings_outside_backfill_window
    first, last = BackfillRun.where(status: "done").pick(Arel.sql("MIN(day)"), Arel.sql("MAX(day)"))
    return check(:info, "No completed backfill days to compare filing dates against") if first.nil?

    count = form4.where(source: "daily_index").where("filed_on < ? OR filed_on > ?", first, last).count
    return check(:pass, "Every backfilled filing is dated inside the backfilled range") if count.zero?

    check(:warn, "#{count} backfilled filings are dated outside #{first} to #{last}",
          "A day's index lists what EDGAR disseminated that day, which can include a filing dated earlier. They are valid filings.")
  end

  def filings_without_transactions
    count = form4.parsed.where("NOT EXISTS (SELECT 1 FROM insider_transactions t WHERE t.filing_id = filings.id)").count

    check(:info, "#{count} parsed filings report no transactions (holdings only)")
  end
end
