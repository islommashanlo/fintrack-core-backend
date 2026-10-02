# frozen_string_literal: true

namespace :enrich do
  desc "Dry-run or execute OpenFIGI CUSIP enrichment; execution requires confirm"
  task :cusips, %i[confirm] => :environment do |_, args|
    enrichment = OpenfigiEnrichment.new
    plan = enrichment.plan
    key_state = ENV["OPENFIGI_API_KEY"].present? ? "authenticated" : "unauthenticated"
    puts "OpenFIGI enrichment: #{plan.cusips.size} CUSIPs, #{plan.request_count} requests " \
         "in batches of #{plan.batch_size} (#{key_state})."

    next unless args[:confirm].to_s.casecmp("confirm").zero?

    puts "Mapped #{enrichment.execute(plan)} OpenFIGI result entries."
  end
end

namespace :position_diffs do
  desc "Materialize SQL-computed institutional position diffs"
  task :materialize, %i[institutional_filer_id period_of_report] => :environment do |_, args|
    abort "Usage: rake position_diffs:materialize[FILER_ID,YYYY-MM-DD]" if args[:institutional_filer_id].blank?

    count = InstitutionalPositionDiffMaterializer.call(
      institutional_filer_id: args[:institutional_filer_id].to_i,
      period_of_report: args[:period_of_report].presence
    )
    puts "Materialized #{count} position diffs."
  end
end
