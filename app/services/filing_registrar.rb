# frozen_string_literal: true

# Records filings we have just learned about and queues the new ones for parsing.
# Idempotent: a filing already known, from either source, is neither re-inserted nor re-queued.
class FilingRegistrar
  # Returns the accession numbers that were new.
  def self.register(refs, source:)
    now = Time.current
    rows = refs.select { |ref| Filing::FORM4_TYPES.include?(ref.form_type) }.uniq(&:accession_no).map do |ref|
      ref.to_h.merge(source:, parse_status: "pending", created_at: now, updated_at: now)
    end
    return [] if rows.empty?

    inserted = Filing.insert_all(rows, unique_by: :accession_no, returning: %w[accession_no]).rows.flatten
    inserted.each { |accession_no| ParseForm4Job.perform_later(accession_no) }
    inserted
  end
end
