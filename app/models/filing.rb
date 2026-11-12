# frozen_string_literal: true

class Filing < ApplicationRecord
  FORM4_TYPES = %w[4 4/A].freeze
  FORM13F_TYPES = %w[13F-HR 13F-HR/A 13F-NT].freeze
  SEC_INGEST_TYPES = (FORM4_TYPES + FORM13F_TYPES).freeze
  PARSE_STATUSES = %w[pending parsed failed].freeze
  ACCESSION_FORMAT = /\A\d{10}-\d{2}-\d{6}\z/

  has_many :insider_transactions, dependent: :restrict_with_exception
  has_many :in_app_notifications, dependent: :restrict_with_exception
  has_many :alert_deliveries, dependent: :restrict_with_exception
  has_many :filing_explanations, dependent: :restrict_with_exception
  has_one :institutional_report, dependent: :restrict_with_exception

  validates :accession_no, presence: true, uniqueness: true, format: { with: ACCESSION_FORMAT }
  validates :cik, presence: true, format: { with: /\A\d{10}\z/ }
  validates :form_type, presence: true
  validates :parse_status, inclusion: { in: PARSE_STATUSES }

  scope :form4, -> { where(form_type: FORM4_TYPES) }
  scope :form13f, -> { where(form_type: FORM13F_TYPES) }
  scope :pending, -> { where(parse_status: "pending") }
  scope :parsed, -> { where(parse_status: "parsed") }
  scope :failed, -> { where(parse_status: "failed") }
  scope :amendments, -> { where(form_type: "4/A") }
  # Filings whose content still stands: nothing later has replaced them.
  scope :current, -> { where(superseded_by_accession_no: nil) }

  def amendment?
    form_type.end_with?("/A")
  end

  def superseded?
    superseded_by_accession_no.present?
  end

  # The complete submission text file, which holds the header and every document.
  def edgar_url
    "https://www.sec.gov/Archives/edgar/data/#{Cik.path_segment(cik)}/#{accession_no}.txt"
  end

  alias sec_url edgar_url

  def data_age_days(as_of: Time.current)
    return unless filed_at

    (as_of.to_date - filed_at.to_date).to_i
  end
end
