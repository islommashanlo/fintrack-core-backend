# frozen_string_literal: true

class FilingsController < ApplicationController
  allow_unauthenticated_access

  def show
    @filing = Filing.includes(:insider_transactions, institutional_report: :institutional_report_managers)
                    .find_by!(accession_no: params[:accession_no])
    @transactions = @filing.insider_transactions.order(:security_table, :owner_seq, :txn_seq)
    @report = @filing.institutional_report
    @holdings = @report ? @report.institutional_holdings.order(:row_seq).limit(100) : []
    @managers = @report ? @report.institutional_report_managers.order(:sequence_no) : []
    @parse_failure = ParseFailure.find_by(accession_no: @filing.accession_no)
  end
end
