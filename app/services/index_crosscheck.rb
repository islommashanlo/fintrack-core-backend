# frozen_string_literal: true

# Compares the Form 4 filings we hold for a day with EDGAR's daily index for that day.
# Used by `rake validate:crosscheck`. Costs two SEC requests.
class IndexCrosscheck
  Result = Data.define(:day, :index_available, :in_index, :in_database, :missing, :unexpected) do
    def consistent?
      index_available && missing.empty?
    end
  end

  def initialize(index: Edgar::DailyIndex.new)
    @index = index
  end

  def call(day)
    held = Filing.form4.where(filed_on: day).pluck(:accession_no)
    return Result.new(day:, index_available: false, in_index: 0, in_database: held.size, missing: [], unexpected: held) unless @index.available?(day)

    listed = @index.fetch(day).map(&:accession_no)
    known = Filing.where(accession_no: listed).pluck(:accession_no)

    Result.new(
      day:, index_available: true, in_index: listed.size, in_database: held.size,
      missing: listed - known,   # in the index, not in our database at all
      unexpected: held - listed  # we date it to this day but the day's index does not list it
    )
  end
end
