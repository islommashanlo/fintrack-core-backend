# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Concurrent filing explanations", type: :model do
  self.use_transactional_tests = false

  it "generates one cached result when concurrent requests use the same filing" do
    filing = create(:filing)
    threads = 4.times.map do
      Thread.new do
        ApplicationRecord.connection_pool.with_connection do
          FilingExplanations::Generate.call(filing: Filing.find(filing.id))
        end
      end
    end
    results = threads.map(&:value)
    expect(results.map { |result| result.explanation.id }.uniq.size).to eq(1)
    expect(results.count { |result| !result.cached }).to eq(1)
    expect(filing.filing_explanations.count).to eq(1)
  ensure
    threads&.each(&:join)
    FilingExplanation.where(filing_id: filing.id).delete_all if filing
    filing&.destroy!
  end
end
