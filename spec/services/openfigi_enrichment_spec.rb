# frozen_string_literal: true

require "rails_helper"

RSpec.describe OpenfigiEnrichment do
  it "plans only valid distinct CUSIPs using the client's batch size" do
    client = instance_double(OpenfigiClient, batch_size: 2)
    enrichment = described_class.new(client:)

    plan = enrichment.plan(cusips: [ "037833100", "bad", "037833100", "594918104", "023135106" ])

    expect(plan).to have_attributes(cusips: [ "023135106", "037833100", "594918104" ], request_count: 2, batch_size: 2)
  end

  it "passes client results to the mapping ingestor" do
    result = instance_double(OpenfigiResponseParser::Result, cusip: "037833100")
    client = instance_double(OpenfigiClient, batch_size: 10, map: [ result ])
    ingestor = class_spy(CusipSecurityMappingIngestor)
    plan = described_class.new(client:, ingestor:).plan(cusips: [ "037833100" ])

    expect(described_class.new(client:, ingestor:).execute(plan)).to eq(1)
    expect(ingestor).to have_received(:call).with([ result ])
  end
end
