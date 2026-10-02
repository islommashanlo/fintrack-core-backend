# frozen_string_literal: true

# Plans and executes CUSIP enrichment. Planning is read-only; execution is
# intentionally explicit because an initial unauthenticated run can be slow.
class OpenfigiEnrichment
  Plan = Data.define(:cusips, :request_count, :batch_size)

  def initialize(client: OpenfigiClient.new, ingestor: CusipSecurityMappingIngestor)
    @client = client
    @ingestor = ingestor
  end

  def plan(cusips: nil)
    values = cusips || InstitutionalHolding.where.not(cusip: nil).distinct.pluck(:cusip)
    values = values.filter { |cusip| cusip.match?(/\A[0-9A-Z]{9}\z/) }.uniq.sort
    batch_size = @client.batch_size

    Plan.new(cusips: values, request_count: (values.length.to_f / batch_size).ceil, batch_size:)
  end

  def execute(plan)
    results = @client.map(plan.cusips)
    @ingestor.call(results)
    results.size
  end
end
