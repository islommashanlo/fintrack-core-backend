# frozen_string_literal: true

require "rails_helper"

RSpec.describe Form13fInformationTableParser do
  def parse(name)
    described_class.parse(form13f_information(name))
  end

  it "parses every committed information-table fixture" do
    expected_counts = {
      recent_2026_q1: 146,
      amendment_2026_q1: 27,
      post_cutoff_2022_q4: 23,
      post_cutoff_2023_q1: 56,
      pre_cutoff_2022_q3: 41,
      combination_put_call_2024_q2: 1790
    }

    expected_counts.each do |name, count|
      rows = parse(name)
      expect(rows.length).to eq(count), "#{name} row count"
      expect(rows.map(&:row_seq)).to eq((1..count).to_a)
    end
  end

  it "keeps reported values, share types and voting authority as separate fields" do
    old_row = parse(:pre_cutoff_2022_q3).first
    new_row = parse(:post_cutoff_2022_q4).first

    expect(old_row).to have_attributes(
      name_of_issuer: "ABBVIE INC", title_of_class: "COM",
      cusip: "00287Y109", value_reported: BigDecimal("78819"), shares: BigDecimal("587278"), share_type: "SH"
    )
    expect(new_row).to have_attributes(
      value_reported: BigDecimal("1602900"), shares: BigDecimal("90000"), share_type: "SH",
      voting_sole: BigDecimal("0"), voting_shared: BigDecimal("90000"), voting_none: BigDecimal("0")
    )
  end

  it "retains repeated CUSIPs as distinct rows and reads put/call values" do
    rows = parse(:combination_put_call_2024_q2)
    repeated = rows.select { |row| row.cusip == "88579Y101" }

    expect(repeated.length).to eq(2)
    expect(repeated.map(&:put_call)).to eq([ nil, "Call" ])
    expect(rows.map(&:put_call).compact).to include("Call", "Put")
    expect(repeated.map(&:row_seq)).to eq([ 1, 2 ])
  end

  it "reads other-manager references when the information table reports them" do
    rows = parse(:post_cutoff_2023_q1)

    expect(rows.map(&:other_manager).compact.uniq).to contain_exactly("1", "2")
    expect(rows.first).to have_attributes(investment_discretion: "DFND", figi: nil)
  end

  it "streams a large table and remains pure" do
    queries = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") { |*, payload| queries << payload[:sql] }

    expect(parse(:combination_put_call_2024_q2).length).to eq(1790)
    expect(queries).to be_empty
    expect(a_request(:any, //)).not_to have_been_made
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  describe "malformed input" do
    let(:xml) { form13f_information(:recent_2026_q1) }

    it "raises its deterministic parser error" do
      {
        "" => /empty document/,
        "<informationTable><infoTable>" => /invalid XML/,
        "<somethingElse/>" => /root element is not informationTable/,
        xml.sub("<ns1:cusip>88579Y101</ns1:cusip>", "") => /missing cusip/,
        xml.sub("<ns1:value>9005</ns1:value>", "<ns1:value>many</ns1:value>") => /value is not a number/
      }.each do |input, message|
        expect { described_class.parse(input) }.to raise_error(described_class::MalformedError, message)
      end
    end
  end
end
