# frozen_string_literal: true

# Links Form 4/A amendments to the filing they amend (invariant 4).
#
# A 4/A does not name the original's accession number; it only carries
# dateOfOriginalSubmission. The original is found by issuer + reporting owner + period
# of report, narrowed by that date when several filings qualify. This is a heuristic:
# when it cannot decide, the amendment is left unmatched with a reason instead of guessing.
#
# Nothing is deleted. Every filing in a chain except the newest gets
# superseded_by_accession_no pointing at the newest, whatever order they were ingested in.
class AmendmentMatcher
  AMBIGUOUS = "ambiguous_original"
  BEFORE_COVERAGE = "original_before_coverage"
  NOT_FOUND = "original_not_found"

  # Call after any Form 4 or 4/A has been ingested.
  def self.after_ingest(filing)
    if filing.amendment?
      new(filing).link
    else
      waiting_amendments_for(filing).each { |amendment| new(amendment).link }
    end
  end

  def self.waiting_amendments_for(original)
    Filing.amendments.parsed
          .where(issuer_cik: original.issuer_cik, period_of_report: original.period_of_report, amends_accession_no: nil)
          .where("owner_ciks && ARRAY[?]::varchar[]", original.owner_ciks)
          .where("filed_at > ?", original.filed_at)
  end

  def initialize(amendment)
    @amendment = amendment
  end

  def link
    originals = candidates
    originals = originals.select { |f| f.filed_on == @amendment.date_of_original_submission }.presence || originals

    case originals.size
    when 1 then supersede(originals.first)
    when 0 then @amendment.update!(amends_accession_no: nil, unmatched_reason: missing_reason)
    else @amendment.update!(amends_accession_no: nil, unmatched_reason: AMBIGUOUS)
    end
  end

  private

  # Earlier original (non-amendment) filings by the same owner for the same issuer and period.
  def candidates
    Filing.parsed.where(form_type: "4")
          .where(issuer_cik: @amendment.issuer_cik, period_of_report: @amendment.period_of_report)
          .where("owner_ciks && ARRAY[?]::varchar[]", @amendment.owner_ciks)
          .where("filed_at < ?", @amendment.filed_at)
          .order(:filed_at)
          .to_a
  end

  def supersede(original)
    @amendment.update!(amends_accession_no: original.accession_no, unmatched_reason: nil)

    chain = [ original ] + Filing.where(amends_accession_no: original.accession_no).order(:filed_at, :accession_no).to_a
    newest = chain.last
    chain.each do |filing|
      filing.update!(superseded_by_accession_no: filing == newest ? nil : newest.accession_no)
    end
  end

  def missing_reason
    original_date = @amendment.date_of_original_submission
    earliest_covered = Filing.form4.minimum(:filed_on)

    original_date && earliest_covered && original_date < earliest_covered ? BEFORE_COVERAGE : NOT_FOUND
  end
end
