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
      due_date: Date.new(2027, 2, 16),
      days_remaining: 91
    )
  end

  it "keeps a weekday deadline unchanged" do
    deadline = described_class.new(today: Date.new(2026, 7, 1)).next

    expect(deadline).to have_attributes(
      period_end: Date.new(2026, 6, 30),
      due_date: Date.new(2026, 8, 14)
    )
  end

  it "keeps the current deadline visible through its due date" do
    deadline = described_class.new(today: Date.new(2026, 11, 16)).next
    expect(deadline).to have_attributes(due_date: Date.new(2026, 11, 16), days_remaining: 0)
  end

  it "rolls February weekends past Washington's Birthday without treating every February Monday as a holiday" do
    { 2025 => 14, 2026 => 17, 2027 => 16, 2028 => 14 }.each do |year, day|
      deadline = described_class.new(today: Date.new(year, 1, 1)).next
      expect(deadline.due_date).to eq(Date.new(year, 2, day))
    end
  end
end
