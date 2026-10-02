# frozen_string_literal: true

# Write-once store for raw filings (invariant 3). An archived filing is never replaced,
# so the pipeline can always re-parse exactly what the SEC served.
#
# This is the local-disk implementation. Production needs object storage behind the
# same three methods (store, read, exist?); see docs/plan-phase-2.md.
class FilingArchive
  class MissingError < StandardError; end

  def self.default
    new(root: ENV.fetch("FILING_ARCHIVE_ROOT") { Rails.root.join("storage/filings").to_s })
  end

  def initialize(root:)
    @root = Pathname.new(root)
  end

  # Returns the archive path to keep in filings.raw_path.
  def store(accession_no, body)
    path = path_for(accession_no)
    store_path(path, body)
  end

  # Archives a 13F document under its manager, accession and original SEC filename.
  # The filename is kept because information-table document names vary by filing.
  def store_13f(manager_cik:, year:, accession_no:, filename:, body:)
    manager_cik = Cik.normalize(manager_cik)
    year = Integer(year.to_s, 10)
    raise ArgumentError, "invalid archive year: #{year.inspect}" unless year.between?(1900, 2100)
    raise ArgumentError, "not an accession number: #{accession_no.inspect}" unless accession_no.to_s.match?(Filing::ACCESSION_FORMAT)

    filename = filename.to_s
    raise ArgumentError, "invalid archive filename: #{filename.inspect}" unless safe_filename?(filename)

    path = "13f/#{manager_cik}/#{year}/#{accession_no}/#{filename}"
    store_path(path, body)
  rescue ArgumentError
    raise
  rescue StandardError => e
    raise ArgumentError, "invalid 13F archive path: #{e.message}"
  end

  def read(path)
    @root.join(path).binread
  rescue Errno::ENOENT
    raise MissingError, "no archived filing at #{path}"
  end

  def exist?(path)
    path.present? && @root.join(path).file?
  end

  # <filer agent prefix>/<two-digit year>/<accession>.txt
  def path_for(accession_no)
    raise ArgumentError, "not an accession number: #{accession_no.inspect}" unless accession_no.to_s.match?(Filing::ACCESSION_FORMAT)

    prefix, year, = accession_no.split("-")
    "#{prefix}/#{year}/#{accession_no}.txt"
  end

  private

  def store_path(path, body)
    target = @root.join(path)
    return path if target.exist?

    target.dirname.mkpath
    temp = target.sub_ext(".#{Process.pid}.#{Thread.current.object_id}.tmp")
    temp.binwrite(body)
    temp.rename(target)
    path
  end

  def safe_filename?(filename)
    filename == File.basename(filename) && filename.match?(%r{\A[A-Za-z0-9][A-Za-z0-9_.-]*\z})
  end
end
