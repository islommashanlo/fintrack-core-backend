# frozen_string_literal: true

# Calculates the next quarterly 13F filing deadline without consulting an
# external calendar. The statutory 45-day date rolls forward when it lands on
# a weekend, which keeps the product's countdown useful at quarter end.
class Form13fDeadline
  Deadline = Data.define(:period_end, :due_date, :days_remaining)
  QUARTER_ENDS = [ [ 3, 31 ], [ 6, 30 ], [ 9, 30 ], [ 12, 31 ] ].freeze

  def initialize(today: Date.current)
    @today = today.to_date
  end

  def next
    period_end = quarter_ends.find do |candidate|
      business_day(candidate + 45.days) > @today
    end
    due_date = business_day(period_end + 45.days)

    Deadline.new(period_end, due_date, (due_date - @today).to_i)
  end

  private

  def quarter_ends
    ((@today.year - 1)..(@today.year + 1)).flat_map do |year|
      QUARTER_ENDS.map { |month, day| Date.new(year, month, day) }
    end
  end

  def business_day(date)
    date += 1 while date.saturday? || date.sunday?
    date
  end
end
