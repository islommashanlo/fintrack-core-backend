# frozen_string_literal: true

# EDGAR writes a CIK three ways: zero-padded to ten digits (filing XML, search hits),
# unpadded (index files) and as a bare integer in archive paths. We store the padded form.
module Cik
  module_function

  def normalize(value)
    digits = value.to_s.strip
    raise ArgumentError, "not a CIK: #{value.inspect}" unless digits.match?(/\A\d{1,10}\z/)

    digits.rjust(10, "0")
  end

  # The form used in /Archives/edgar/data/<cik>/ paths.
  def path_segment(value)
    normalize(value).to_i.to_s
  end
end
