# frozen_string_literal: true

# Rebuilds derived position diffs for one filer/period from the SQL query. The
# derived rows may be replaced when an amendment changes effective holdings;
# the as-reported institutional reports and holdings are never deleted.
class InstitutionalPositionDiffMaterializer
  class NaturalKeyCollisionError < StandardError; end

  def self.call(institutional_filer_id:, period_of_report: nil, now: Time.current)
    new(institutional_filer_id:, period_of_report:, now:).call
  end

  def initialize(institutional_filer_id:, period_of_report:, now:)
    @institutional_filer_id = institutional_filer_id
    @period_of_report = period_of_report
    @now = now
  end

  def call
    rows = InstitutionalPositionDiffQuery.new(
      institutional_filer_id: @institutional_filer_id,
      period_of_report: @period_of_report
    ).call
    records = rows.map { |row| record(row) }
    assert_unique_keys!(records)

    PositionDiff.transaction do
      scope = PositionDiff.where(institutional_filer_id: @institutional_filer_id)
      scope = scope.where(period_of_report: @period_of_report) if @period_of_report
      scope.delete_all
      PositionDiff.upsert_all(records, unique_by: :index_position_diffs_on_natural_key) if records.any?
    end
    records.size
  end

  private

  def record(row)
    {
      institutional_filer_id: row.fetch("institutional_filer_id"),
      institutional_report_id: row.fetch("current_report_id"),
      prior_institutional_report_id: row["prior_report_id"],
      period_of_report: row.fetch("period_of_report"),
      prior_period_of_report: row["prior_period_of_report"],
      cusip: row.fetch("cusip"),
      put_call: row["put_call"].to_s,
      share_type: row.fetch("share_type"),
      change_type: row.fetch("change_type"),
      shares_before: row["shares_before"],
      shares_after: row["shares_after"],
      shares_delta: row.fetch("shares_delta"),
      value_usd_before: row["value_usd_before"],
      value_usd_after: row["value_usd_after"],
      value_usd_delta: row["value_usd_delta"],
      name_of_issuer: row["name_of_issuer"],
      title_of_class: row["title_of_class"],
      current_suspect: row.fetch("current_suspect"),
      prior_suspect: row.fetch("prior_suspect"),
      calculated_at: @now,
      created_at: @now,
      updated_at: @now
    }
  end

  def assert_unique_keys!(records)
    duplicate = records.group_by { |record| PositionDiff::NATURAL_KEY.map { |key| record.fetch(key) } }
                      .find { |_key, values| values.length > 1 }&.first
    return unless duplicate

    raise NaturalKeyCollisionError, "duplicate position diff natural key in one batch: #{duplicate.inspect}"
  end
end
