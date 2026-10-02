# frozen_string_literal: true

# One row per filing that could not be processed. Rows are never deleted; a later
# success stamps resolved_at.
class ParseFailure < ApplicationRecord
  validates :accession_no, presence: true, uniqueness: true
  validates :error, presence: true

  scope :unresolved, -> { where(resolved_at: nil) }

  def self.record!(accession_no, error)
    message = error.is_a?(Exception) ? "#{error.class.name}: #{error.message}" : error.to_s
    now = Time.current

    upsert(
      { accession_no:, error: message.truncate(2000), attempts: 1, last_failed_at: now, resolved_at: nil },
      unique_by: :accession_no,
      on_duplicate: Arel.sql(
        "error = EXCLUDED.error, attempts = parse_failures.attempts + 1, " \
        "last_failed_at = EXCLUDED.last_failed_at, resolved_at = NULL, updated_at = EXCLUDED.updated_at"
      )
    )
  end

  def self.resolve!(accession_no)
    unresolved.where(accession_no:).update_all(resolved_at: Time.current, updated_at: Time.current)
  end
end
