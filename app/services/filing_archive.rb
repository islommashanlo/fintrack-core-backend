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
    target = @root.join(path)
    return path if target.exist?

    target.dirname.mkpath
    temp = target.sub_ext(".#{Process.pid}.#{Thread.current.object_id}.tmp")
    temp.binwrite(body)
    temp.rename(target)
    path
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
end
