# frozen_string_literal: true

module News
  module Publication
    module_function

    def providers
      ENV.fetch("NEWS_PUBLIC_PROVIDERS", "").split(",").map(&:strip).reject(&:empty?).uniq.sort
        .select { |key| key.match?(/\A[a-z][a-z0-9_]{0,39}\z/) }
    end

    # PostgreSQL uses \y for the word boundaries in the current product policy.
    def language_pattern
      Policy::BannedLanguageScan::BANNED_TERMS.source.gsub('\\b') { '\\y' }
    end
  end
end
