# frozen_string_literal: true

module Api
  module V1
    module InstitutionalHoldingKey
      # Grouping queries alias their reported information-table rows as h.
      VALID_SQL = "h.cusip ~ '^[0-9A-Z]{9}$' AND h.share_type IN ('SH', 'PRN') AND (h.put_call IS NULL OR h.put_call IN ('PUT', 'CALL'))".freeze
    end
  end
end
