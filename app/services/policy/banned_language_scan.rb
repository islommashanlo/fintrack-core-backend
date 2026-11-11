# frozen_string_literal: true

module Policy
  class BannedLanguageScan
    ROOTS = %w[app/serializers app/mailers config/locales app/prompts lib/prompts config/activity_methodology.yml app/services/activity_scoring
      app/services/filing_explanations
      app/services/transaction_alert_text.rb
      app/services/cluster_alert_text.rb
      app/views/filing_alert_mailer app/views/filing_digest_mailer app/views/passwords_mailer
      app/views/layouts/mailer.html.erb app/views/layouts/mailer.text.erb].freeze
    FILE_EXTENSIONS = %w[.rb .erb .json .md .txt .yml .yaml].freeze
    BANNED_TERMS = /\b(?:buy|sell|bullish|bearish|strong\s+buy|opportunity)\b/i
    Violation = Data.define(:path, :line, :text)

    def initialize(root: Rails.root)
      @root = Pathname(root)
    end

    def violations
      ROOTS.flat_map { |relative| files_for(relative) }.flat_map do |path|
        scan_file(path)
      end
    end

    def scan_text(text, path: "inline")
      text.to_s.each_line.with_index(1).filter_map do |line, number|
        next unless line.match?(BANNED_TERMS)

        Violation.new(path:, line: number, text: line.strip)
      end
    end

    private

    def files_for(relative)
      directory = @root.join(relative)
      return [ directory ] if directory.file? && FILE_EXTENSIONS.include?(directory.extname)
      return [] unless directory.directory?

      directory.glob("**/*").select { |path| path.file? && FILE_EXTENSIONS.include?(path.extname) }
    end

    def scan_file(path)
      scan_text(path.read, path: path.relative_path_from(@root).to_s)
    end
  end
end
