# frozen_string_literal: true

module Filing13fFixtures
  COVER_FIXTURES = %i[
    recent_2026_q1 amendment_2026_q1 notice_2026_q1 post_cutoff_2022_q4 post_cutoff_2023_q1
    pre_cutoff_2022_q3 combination_put_call_2024_q2
  ].freeze

  INFORMATION_FIXTURES = %i[
    recent_2026_q1 amendment_2026_q1 post_cutoff_2022_q4 post_cutoff_2023_q1
    pre_cutoff_2022_q3 combination_put_call_2024_q2
  ].freeze

  def form13f_fixture(kind, name)
    Rails.root.join("spec/fixtures/13f/#{name}_#{kind}.xml").binread
  end

  def form13f_cover(name)
    form13f_fixture("cover", name)
  end

  def form13f_information(name)
    form13f_fixture("information", name)
  end
end

RSpec.configure do |config|
  config.include Filing13fFixtures
end
