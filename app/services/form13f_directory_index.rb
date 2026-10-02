# frozen_string_literal: true

# Resolves the cover and information-table filenames from the SEC filing index.
# The resolver uses the filing index's document descriptions, so it never guesses a
# filename from an accession or a manager name.
class Form13fDirectoryIndex
  class MalformedError < StandardError; end

  Document = Data.define(:filename, :description) do
    def xml?
      filename.match?(/\.xml\z/i)
    end

    def information_table?
      xml? && description.match?(/information\s+table/i)
    end
  end

  def self.parse(body)
    new(body).parse
  end

  def initialize(body)
    @body = body.to_s
  end

  def parse
    documents = json_documents || html_documents
    raise MalformedError, "filing index has no document rows" if documents.empty?

    Index.new(documents)
  rescue JSON::ParserError
    Index.new(html_documents)
  end

  Index = Data.define(:documents) do
    def xml_documents?
      documents.any?(&:xml?)
    end

    def cover
      candidates = documents.reject(&:information_table?).select do |document|
        next false unless document.xml?

        document.description.match?(/13F(?:-HR|\s+NOTICE)|cover\s+page|primary/i)
      end
      raise MalformedError, "filing index has no unambiguous 13F cover document" unless candidates.one?

      candidates.first
    end

    def information_table
      candidates = documents.select(&:information_table?)
      raise MalformedError, "filing index has multiple information-table documents" if candidates.length > 1

      candidates.first
    end
  end

  private

  def json_documents
    data = JSON.parse(@body)
    items = data.dig("directory", "item") || data["documents"]
    return nil unless items.is_a?(Array)

    items.filter_map do |item|
      next unless item.is_a?(Hash)

      filename = item["name"] || item["filename"]
      description = [ item["description"], item["documentType"], item["document_type"] ].compact.join(" ")
      Document.new(filename: File.basename(filename), description: description)
    end
  end

  def html_documents
    return [] if @body.strip.empty?

    document = Nokogiri::HTML(@body) { |config| config.nonet }
    document.xpath("//tr").filter_map do |row|
      link = row.at_xpath(".//a[@href]")
      next unless link

      path = URI.parse(link["href"]).path
      filename = File.basename(path.to_s)
      description = row.text.gsub(/\s+/, " ").strip
      Document.new(filename:, description:)
    rescue URI::InvalidURIError
      next
    end
  rescue Nokogiri::SyntaxError => e
    raise MalformedError, "invalid filing index HTML: #{e.message}"
  end
end
