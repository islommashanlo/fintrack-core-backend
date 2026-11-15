# frozen_string_literal: true

# Explicit per-accession evidence; no date/period or process-wide unit assumption.
class Form13fValueUnitPolicy
  def self.load
    config = YAML.safe_load_file(Rails.root.join("config/form13f_value_units.yml"))
    raise ArgumentError, "Invalid 13F unit policy" unless config.is_a?(Hash) && config.keys == [ "filings" ]
    new(assignments: config.fetch("filings"))
  end

  def self.canonical_unit(value)
    unit = Form13fValueNormalizer.normalize(value_reported: 0, value_unit: value).value_unit
    raise ArgumentError, "Unsupported 13F value unit" unless %w[whole_dollars thousands unresolved].include?(unit)
    unit
  end

  def initialize(assignments: {})
    raise ArgumentError, "Invalid 13F accession assignments" unless assignments.is_a?(Hash)
    @units = assignments.to_h do |accession, entry|
      unless accession.is_a?(String) && Filing::ACCESSION_FORMAT.match?(accession) && entry.is_a?(Hash) &&
          entry.keys.sort == %w[evidence value_unit] && entry["evidence"].is_a?(String) && entry["evidence"].present? && entry["evidence"].length <= 2000
        raise ArgumentError, "Invalid 13F accession evidence"
      end
      unit = self.class.canonical_unit(entry.fetch("value_unit"))
      raise ArgumentError, "13F assignments must specify a known unit" if unit == "unresolved"
      [ accession.dup.freeze, unit.freeze ]
    end.freeze
    freeze
  end

  def unit_for(accession)
    @units.fetch(accession, "unresolved")
  end
end
