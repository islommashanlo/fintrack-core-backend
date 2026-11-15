# frozen_string_literal: true

# Records filings we have just learned about and queues the new ones for parsing.
# Idempotent: a filing already known, from either source, is neither re-inserted nor re-queued.
class FilingRegistrar
  # Returns the accession numbers that were new.
  def self.register(refs, source:, value_unit: nil, value_units: {})
    holdings = refs.select { |ref| %w[13F-HR 13F-HR/A].include?(ref.form_type) }.map(&:accession_no).uniq
    raise ArgumentError, "Multiple holdings filings require per-accession value_units" if value_unit.present? && holdings.size > 1
    raise ArgumentError, "Invalid per-accession units" unless value_units.is_a?(Hash) && value_units.keys.all? { |key| key.is_a?(String) && Filing::ACCESSION_FORMAT.match?(key) }
    value_units = value_units.transform_values { |unit| Form13fValueUnitPolicy.canonical_unit(unit) }
    value_unit = Form13fValueUnitPolicy.canonical_unit(value_unit) if value_unit.present?
    now = Time.current
    rows = refs.select { |ref| Filing::SEC_INGEST_TYPES.include?(ref.form_type) }.uniq(&:accession_no).map do |ref|
      ref.to_h.merge(source:, parse_status: "pending", created_at: now, updated_at: now)
    end
    return [] if rows.empty?

    inserted = Filing.insert_all(rows, unique_by: :accession_no, returning: %w[accession_no]).rows.flatten
    Filing.where(accession_no: inserted).pluck(:accession_no, :form_type).each do |accession_no, form_type|
      if Filing::FORM13F_TYPES.include?(form_type)
        job_class = source == "daily_index" ? ParseForm13fBackfillJob : ParseForm13fJob
        selected_unit = value_units.fetch(accession_no, value_unit)
        if selected_unit.present?
          job_class.perform_later(accession_no, value_unit: selected_unit)
        else
          job_class.perform_later(accession_no)
        end
      else
        ParseForm4Job.perform_later(accession_no)
      end
    end
    inserted
  end
end
