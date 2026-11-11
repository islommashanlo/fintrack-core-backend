# frozen_string_literal: true

module FilingExplanations
  class Generate
    PROMPT_VERSION = "facts-v1"
    Result = Data.define(:explanation, :cached)
    class NotReady < StandardError; end
    class Unsupported < StandardError; end

    def self.call(filing:, provider: TemplateProvider.new)
      new(filing:, provider:).call
    end

    def initialize(filing:, provider:)
      @filing = filing
      @provider = provider
    end

    def call
      @filing.with_lock do
        validate_source!
        snapshot = Facts.call(@filing)
        key = { filing: @filing, source_digest: snapshot.digest, prompt_version: PROMPT_VERSION,
                provider_key: @provider.cache_key }
        existing = FilingExplanation.find_by(key)
        return Result.new(explanation: existing, cached: true) if existing

        result, method = generate(snapshot.facts)
        texts = snapshot.facts.index_by { |fact| fact.fetch(:id) }
        body = result.fact_ids.map { |id| texts.fetch(id).fetch(:text) }.join("\n\n")
        coverage = snapshot.coverage.merge(
          "transaction_lines_shown" => result.fact_ids.count { |id| id.start_with?("transaction-") },
          "holding_rows_shown" => result.fact_ids.count { |id| id.start_with?("holding-") }
        ).select { |key, _| snapshot.coverage.key?(key) }
        explanation = FilingExplanation.create!(**key, model: result.model, generation_method: method,
          body:, coverage:, generated_at: Time.current)
        Result.new(explanation:, cached: false)
      end
    end

    private

    def validate_source!
      raise NotReady unless @filing.parse_status == "parsed"
      raise Unsupported unless Filing::SEC_INGEST_TYPES.include?(@filing.form_type)
      return if Filing::FORM4_TYPES.include?(@filing.form_type)

      report = @filing.institutional_report
      raise Unsupported if report&.skipped?
      raise NotReady unless report&.status == "parsed"
    end

    def generate(facts)
      prompt = Rails.root.join("app/prompts/filing_explanations/system.txt").read
      2.times do
        result = @provider.generate(system_prompt: prompt, facts: facts.deep_dup)
        return [ result, @provider.is_a?(TemplateProvider) ? "template" : "provider" ] if valid?(result, facts)
      end
      fallback(facts)
    rescue Provider::Unavailable
      fallback(facts)
    end

    def valid?(result, facts)
      return false unless result.is_a?(Provider::Result)
      return false unless result.model.is_a?(String) && result.model.match?(/\A[a-zA-Z0-9][a-zA-Z0-9._:-]{0,119}\z/)
      return false if Policy::BannedLanguageScan.new.scan_text(result.model).any?

      ids = result.fact_ids
      return false unless ids.is_a?(Array) && ids.all? { |id| id.is_a?(String) } && ids.uniq == ids

      known = facts.map { |fact| fact.fetch(:id) }
      required = facts.select { |fact| fact.fetch(:required) }.map { |fact| fact.fetch(:id) }
      return false unless (ids - known).empty? && (required - ids).empty?

      # Keep a representative line when rows exist, even if the adapter omits others.
      optional = known - required
      return false if optional.any? && (ids & optional).empty?

      text = facts.select { |fact| ids.include?(fact.fetch(:id)) }.map { |fact| fact.fetch(:text) }.join("\n")
      Policy::BannedLanguageScan.new.scan_text(text).empty?
    end

    def fallback(facts)
      [ TemplateProvider.new.generate(system_prompt: "", facts:), "template" ]
    end
  end
end
