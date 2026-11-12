# frozen_string_literal: true

# Bounded local metadata probes; never fetches, parses, repairs or reads document bodies.
class ArchiveVerification
  MAX_LIMIT = 500

  def initialize(limit: 100, after_id: 0, filing_ceiling: nil, archive: FilingArchive.default)
    @limit = Integer(limit.to_s, 10)
    @after_id = Integer(after_id.to_s, 10)
    @ceiling = filing_ceiling.nil? ? (Filing.maximum(:id) || 0) : Integer(filing_ceiling.to_s, 10)
    raise ArgumentError, "limit must be between 1 and #{MAX_LIMIT}" unless @limit.between?(1, MAX_LIMIT)
    raise ArgumentError, "after_id and filing_ceiling must be nonnegative" if @after_id.negative? || @ceiling.negative?

    @archive = archive
  end

  def call
    ids = Filing.parsed.where(form_type: Filing::SEC_INGEST_TYPES, id: (@after_id + 1)..@ceiling)
      .order(:id).limit(@limit + 1).pluck(:id)
    more = ids.size > @limit
    ids = ids.first(@limit)
    inventory = ArchiveInventory.new(filing_ids: ids)
    documents = inventory.documents.map do |document|
      document.except("path").merge("status" => @archive.probe(document.fetch("path")))
    end
    { filing_ceiling: @ceiling, scanned_filings: ids.size, checked_documents: documents.size,
      has_more: more, next_after_id: more ? ids.last : nil, metadata_only: true,
      coverage: inventory.coverage, status_counts: documents.map { |document| document.fetch("status") }.tally, documents: }
  end
end
