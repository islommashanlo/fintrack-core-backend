# frozen_string_literal: true

require "rails_helper"

RSpec.describe Form13fDeadline do
  it "rolls the September 2026 deadline from Saturday to Monday" do
    deadline = described_class.new(today: Date.new(2026, 10, 2)).next

    expect(deadline).to have_attributes(
      period_end: Date.new(2026, 9, 30),
      due_date: Date.new(2026, 11, 16),
      days_remaining: 45
    )
  end

  it "moves to the next quarter after a deadline has passed" do
    deadline = described_class.new(today: Date.new(2026, 11, 17)).next

    expect(deadline).to have_attributes(
      period_end: Date.new(2026, 12, 31),
      due_date: Date.new(2027, 2, 15),
      days_remaining: 90
    )
  end

  it "keeps a weekday deadline unchanged" do
    deadline = described_class.new(today: Date.new(2026, 7, 1)).next

    expect(deadline).to have_attributes(
      period_end: Date.new(2026, 6, 30),
      due_date: Date.new(2026, 8, 14)
    )
  end
end
