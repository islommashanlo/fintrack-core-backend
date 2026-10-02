# frozen_string_literal: true

# Derives a conservative 10b5-1 status from fields already preserved on a Form 4.
# It never changes the filing or transaction values and returns plain hashes.
class Form4PlanClassifier
  DATE_PATTERN = "(?:January|February|March|April|May|June|July|August|September|October|November|December)\\s+\\d{1,2},\\s+\\d{4}"
  PLAN_PATTERN = /10b5[-\s]?1/i
  ADOPTION_PATTERN = /(?:adopt(?:ed|ion)|entered into)[^.]{0,100}?(#{DATE_PATTERN})/i
  TERMINATION_PATTERN = /(?:terminat(?:ed|ion)|cancel(?:led|ing))[^.]{0,100}?(#{DATE_PATTERN})/i
  OUTSIDE_PLAN_PATTERN = /(?:not\s+(?:made\s+)?pursuant to|outside|not\s+under)[^.]{0,60}10b5[-\s]?1/i
  RELATED_PLAN_PATTERN = /(?:pursuant to|under)[^.]{0,60}10b5[-\s]?1|10b5[-\s]?1[^.]{0,60}(?:pursuant to|under)/i

  def self.annotate_rows(rows)
    rows.map { |row| annotate(row) }
  end

  def self.annotate(row)
    new(row).annotate
  end

  def initialize(row)
    @row = row
  end

  def annotate
    text = relevant_footnotes
    adoption_date = date_from(text, ADOPTION_PATTERN)
    termination_date = date_from(text, TERMINATION_PATTERN)

    @row.except("plan_disclosed", "filing_footnotes", "transaction_footnote_ids").merge(
      "plan_status" => status(text, termination_date),
      "plan_adoption_date" => adoption_date,
      "plan_termination_date" => termination_date
    )
  end

  private

  def relevant_footnotes
    footnotes = parse_footnotes(@row["filing_footnotes"])
    ids = normalize_ids(@row["transaction_footnote_ids"])
    linked = ids.filter_map { |id| footnotes[id] }

    (linked.presence || footnotes.values).join(" ")
  end

  def status(text, termination_date)
    return "10b5-1 plan terminated" if termination_date && text.match?(PLAN_PATTERN)
    return "Outside 10b5-1 plan" if text.match?(OUTSIDE_PLAN_PATTERN)
    return "10b5-1 plan disclosed" if text.match?(RELATED_PLAN_PATTERN)
    return "10b5-1 plan disclosed" if @row["plan_disclosed"] == true || @row["plan_disclosed"] == "t"

    nil
  end

  def date_from(text, pattern)
    match = text.match(pattern)
    return unless match

    Date.parse(match[1])
  rescue Date::Error
    nil
  end

  def parse_footnotes(value)
    parsed = value.is_a?(String) ? JSON.parse(value) : value
    parsed.respond_to?(:to_h) ? parsed.to_h.transform_keys(&:to_s) : {}
  rescue JSON::ParserError
    {}
  end

  def normalize_ids(value)
    return value if value.is_a?(Array)
    return [] if value.blank?

    value.to_s.delete("{}").split(",").map(&:strip)
  end
end
