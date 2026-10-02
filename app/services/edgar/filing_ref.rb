# frozen_string_literal: true

module Edgar
  # What an index or search hit tells us about a filing before we fetch it.
  # `cik` is any CIK the filing is archived under, which is all the fetch URL needs.
  FilingRef = Data.define(:accession_no, :cik, :form_type, :filed_on)
end
