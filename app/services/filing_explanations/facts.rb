# frozen_string_literal: true

module FilingExplanations
  class Facts
    ROW_LIMIT = 8
    OWNER_LIMIT = 8
    MANAGER_LIMIT = 5
    Snapshot = Data.define(:digest, :facts, :coverage)

    def self.call(filing)
      new(filing).call
    end

    def initialize(filing)
      @filing = filing
      @facts = []
      @coverage = {}
      @fingerprints = []
    end

    def call
      fingerprint(Filing.where(id: @filing.id))
      common_facts
      Filing::FORM4_TYPES.include?(@filing.form_type) ? form4_facts : institutional_facts
      Snapshot.new(digest: Digest::SHA256.hexdigest(@fingerprints.join(":")), facts: @facts, coverage: @coverage)
    end

    private

    def add(id, text, required: true)
      @facts << { id:, text:, required: }
    end

    # Hash every normalized row, including rows omitted from the bounded summary.
    # Exclude bookkeeping timestamps so a byte-identical re-ingest retains its cache.
    def fingerprint(scope)
      table = scope.klass.quoted_table_name
      expression = "md5(COALESCE(string_agg(md5((to_jsonb(#{table}) - 'updated_at' - 'created_at' - 'parsed_at')::text), '' ORDER BY #{table}.id), ''))"
      @fingerprints << scope.pick(Arel.sql(expression))
    end

    def common_facts
      add("filing", "Form #{@filing.form_type}, accession #{@filing.accession_no}, filer CIK #{@filing.cik}.")
      add("timing", "Filed at #{timestamp(@filing.filed_at)}; reporting period #{@filing.period_of_report&.iso8601 || 'not recorded'}.")
      if @filing.accepted_at
        add("acceptance", "SEC acceptance recorded at #{timestamp(@filing.accepted_at)}.")
      end
      add("amendment", "This filing is an amendment.") if @filing.amendment?
      if @filing.amends_accession_no
        add("original", "Linked original filing: #{@filing.amends_accession_no}.")
      end
      if @filing.superseded_by_accession_no
        add("superseded", "A later filing supersedes this filing: #{@filing.superseded_by_accession_no}.")
      end
      if @filing.unmatched_reason.present?
        add("unresolved", "The amendment link is unresolved; consult the source filing.")
      end
    end

    def form4_facts
      scope = @filing.insider_transactions
      fingerprint(scope)
      owners = scope.select(:insider_cik).distinct.count
      lines = InsiderTransaction.from(scope.select(:security_table, :txn_seq).distinct, :unique_lines).count
      @coverage = { "transaction_lines" => lines, "reporting_owners" => owners,
                    "transaction_lines_shown" => [ lines, ROW_LIMIT ].min,
                    "reporting_owners_shown" => [ owners, OWNER_LIMIT ].min }
      add("issuer", "Issuer: #{label(@filing.issuer_name, fallback: @filing.issuer_cik || 'not recorded')}" \
                    "#{@filing.issuer_ticker.present? ? " (#{label(@filing.issuer_ticker, fallback: 'symbol omitted')})" : ''}.")
      add("counts", "Stored transaction data contains #{lines} distinct transaction lines and #{owners} reporting owners; joint-owner copies count once.")
      if lines.zero?
        add("empty", "No transaction rows are stored. Consult the source for ownership-only details.")
        @filing.owner_ciks.first(OWNER_LIMIT).each_with_index do |cik, index|
          add("filing-owner-#{index + 1}", "Reporting owner recorded on the filing: CIK #{label(cik)}.")
        end
      end
      owner_rows(scope).each_with_index do |owner, index|
        roles = []
        roles << "director" if owner.is_director
        roles << (label(owner.officer_title, fallback: "officer")) if owner.is_officer
        roles << "10% owner" if owner.is_ten_percent_owner
        roles << "other relationship" if owner.is_other
        add("owner-#{index + 1}", "Reporting owner: #{label(owner.insider_name, fallback: owner.insider_cik)} (CIK #{owner.insider_cik}); " \
                                "relationship: #{roles.presence&.join(', ') || 'not recorded'}.")
      end
      transaction_rows(scope).each_with_index { |row, index| transaction_fact(row, index) }
      add("plan", "The filing's Rule 10b5-1 checkbox is #{@filing.aff10b5_one ? 'checked' : 'not checked'}.") unless @filing.aff10b5_one.nil?
      if @filing.footnotes.any?
        add("footnotes", "The filing stores #{@filing.footnotes.size} footnotes. Footnote wording and all transaction lines are available in the source.")
      end
      add("coverage", "This summary shows at most #{ROW_LIMIT} transaction lines and #{OWNER_LIMIT} reporting owners; it does not total joint-owner copies.")
    end

    def owner_rows(scope)
      InsiderTransaction.from(scope.select("DISTINCT ON (insider_cik) insider_transactions.*")
                                   .order(:insider_cik, :owner_seq, :id), :insider_transactions)
                        .order(:insider_cik).limit(OWNER_LIMIT)
    end

    def transaction_rows(scope)
      InsiderTransaction.from(scope.select("DISTINCT ON (security_table, txn_seq) insider_transactions.*")
                                   .order(:security_table, :txn_seq, :owner_seq, :id), :insider_transactions)
                        .order(:security_table, :txn_seq).limit(ROW_LIMIT)
    end

    def transaction_fact(row, index)
      kind = row.open_market? ? "open-market #{row.direction}" : "administrative transaction"
      text = "#{row.security_table.tr('_', '-')} line #{row.txn_seq}: #{kind}, SEC code #{label(row.transaction_code)}; " \
             "#{number(row.shares)} shares of #{label(row.security_title, fallback: 'reported security')} on #{row.transaction_date&.iso8601 || 'an unrecorded date'}. "
      text += if row.price_suspect
        "The reported price is flagged for review; no transaction value is calculated. "
      elsif row.price
        "Reported price per share: USD #{number(row.price)}; reported shares times price: USD #{number(row.reported_value)}. "
      else
        "No numeric price is stored; no transaction value is calculated. "
      end
      text += "Reported holdings after this line: #{number(row.shares_owned_following)} shares. " if row.shares_owned_following
      ownership = { "D" => "direct", "I" => "indirect" }[row.direct_or_indirect]
      text += "Ownership is #{ownership}. " if ownership
      if row.footnote_ids.any?
        notes = row.footnote_ids.filter_map { |id| @filing.footnotes[id] }
        text += if notes.any? { |note| note.match?(/weighted[ -]average/i) }
          "A linked footnote mentions a weighted-average price; consult execution-price details in the source. "
        else
          "Linked footnotes give additional context; consult their complete wording in the source. "
        end
      end
      add("transaction-#{index + 1}", text.strip, required: false)
    end

    def institutional_facts
      report = @filing.institutional_report
      fingerprint(InstitutionalReport.where(id: report.id))
      fingerprint(InstitutionalFiler.where(id: report.institutional_filer_id))
      fingerprint(report.institutional_report_managers)
      fingerprint(report.institutional_report_other_managers)
      scope = report.institutional_holdings
      fingerprint(scope)
      count, total, missing, suspect = scope.pick(*[ "COUNT(*)", "SUM(value_usd)", "COUNT(*) FILTER (WHERE value_usd IS NULL)", "COUNT(*) FILTER (WHERE suspect)" ].map { |sql| Arel.sql(sql) })
      managers = report.institutional_report_managers.count
      @coverage = { "holding_rows" => count, "holding_rows_shown" => [ count, ROW_LIMIT ].min,
                    "included_managers" => managers, "included_managers_shown" => [ managers, MANAGER_LIMIT ].min }
      add("manager", "Reporting institution: #{label(report.institutional_filer.name, fallback: @filing.cik)} (CIK #{@filing.cik}).")
      add("report", "Report type: #{label(report.report_type)}; period #{report.period_of_report.iso8601}.")
      if report.amendment_type
        text = case report.amendment_type
        when "RESTATEMENT" then "RESTATEMENT replaces the earlier report's holdings; prior filings remain in history."
        when "NEW HOLDINGS" then "NEW HOLDINGS adds reported rows to the earlier report; it is not a complete replacement portfolio."
        else "The amendment type is unrecognized; consult the source."
        end
        add("amendment-kind", text)
      end
      if @filing.form_type == "13F-NT"
        add("notice", "This is a notice that holdings are reported by another manager. No holdings are inferred from the notice.")
      end
      add("cover-count", "Cover-page entry count: #{report.table_entry_total}; stored information-table rows: #{count}.") if report.table_entry_total
      if report.table_value_total
        add("cover-value", "Cover-page total value as reported: #{number(report.table_value_total)} (#{unit(report.cover_value_unit)}).")
      end
      if count.zero?
        add("table-total", "No information-table rows are stored; no holdings value is inferred.")
      else
        add("table-total", "Stored information table: #{count} rows; " \
                           "#{missing.positive? ? 'a complete normalized value total is unavailable' : "normalized reported value USD #{number(total)}"}.")
      end
      if report.suspect || suspect.positive?
        add("suspect", "Integrity review is flagged for #{suspect} holding rows#{report.suspect ? ' and the report' : ''}; reported values have not been corrected.")
      end
      scope.order(:row_seq).limit(ROW_LIMIT).each { |row| holding_fact(row) }
      manager_facts(report, managers)
      add("coverage", "This summary shows at most #{ROW_LIMIT} information-table rows and #{MANAGER_LIMIT} managers from each manager list. Rows sharing a CUSIP remain separate.")
      add("limitations", "Values describe the reported period, not current positions or current market prices. The complete table is available in the source.")
    end

    def manager_facts(report, included_count)
      other_count = report.other_managers_recorded? ? report.institutional_report_other_managers.count : nil
      @coverage.merge!("other_managers_recorded" => report.other_managers_recorded?,
                       "other_managers" => other_count, "other_managers_shown" => [ other_count || 0, MANAGER_LIMIT ].min)
      add("manager-count", "Summary-page other-included-manager count: #{report.other_included_managers_count || 'not recorded'}; stored included-manager records: #{included_count}.")
      if other_count.nil?
        add("other-manager-count", "Cover-page other-manager identities were not captured during ingestion; consult the source filing.")
      else
        add("other-manager-count", "Stored cover-page other-manager records: #{other_count}.")
        manager_rows(report.institutional_report_other_managers, "other-manager", "Cover-page other manager")
      end
      manager_rows(report.institutional_report_managers, "included-manager", "Included manager")
    end

    def manager_rows(scope, id_prefix, description)
      scope.order(:sequence_no).limit(MANAGER_LIMIT).each do |manager|
        identifiers = { "CIK" => manager.cik, "Form 13F file number" => manager.form13f_file_number,
                        "CRD number" => manager.crd_number, "SEC file number" => manager.sec_file_number }
        details = identifiers.filter_map { |key, value| "#{key} #{label(value)}" if value.present? }.join("; ")
        add("#{id_prefix}-#{manager.sequence_no}", "#{description}: #{label(manager.name, fallback: 'name not recorded')}#{details.present? ? " (#{details})" : ''}.")
      end
    end

    def holding_fact(row)
      quantity = { "SH" => "shares", "PRN" => "principal amount" }.fetch(row.share_type, "reported quantity")
      text = "Information-table row #{row.row_seq}: #{label(row.name_of_issuer)}, #{label(row.title_of_class)}, " \
             "CUSIP #{label(row.cusip)}; #{number(row.shares)} #{quantity}. " \
             "Value as reported: #{number(row.value_reported)} (#{unit(row.value_unit)}); normalized USD #{number(row.value_usd)}."
      option = row.put_call.to_s.upcase
      text += " Option type: #{option.downcase}." if %w[PUT CALL].include?(option)
      text += " This row is flagged for integrity review." if row.suspect
      add("holding-#{row.row_seq}", text, required: false)
    end

    def label(value, fallback: "not recorded")
      text = value.to_s.gsub(/[[:cntrl:]]/, " ").squish
      return fallback if text.empty? || text.length > 160 || text.match?(/[<>]/) || Policy::BannedLanguageScan.new.scan_text(text).any?

      text
    end

    def unit(value)
      { "whole_dollars" => "USD", "thousands" => "thousands of USD" }.fetch(value, "unit not recorded")
    end

    def number(value)
      return "not recorded" unless value

      value.to_d.to_s("F").sub(/\.0+\z/, "").sub(/(\.\d*?)0+\z/, '\\1')
    end

    def timestamp(value)
      value&.utc&.iso8601 || "a time not recorded"
    end
  end
end
