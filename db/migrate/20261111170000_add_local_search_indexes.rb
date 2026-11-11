# frozen_string_literal: true

class AddLocalSearchIndexes < ActiveRecord::Migration[8.0]
  def change
    enable_extension "pg_trgm"
    { filings: %w[issuer_name issuer_ticker], insider_transactions: %w[insider_name],
      institutional_filers: %w[name], filers: %w[name], securities: %w[name ticker] }.each do |table, columns|
      columns.each do |column|
        add_index table, "LOWER(#{column}) gin_trgm_ops", using: :gin, name: "search_#{table}_#{column}"
      end
    end
    add_index :filings, "UPPER(issuer_ticker), filed_at DESC, accession_no DESC",
      where: "parse_status = 'parsed' AND form_type IN ('4', '4/A')", name: :search_latest_company_filing
  end
end
