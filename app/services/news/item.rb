# frozen_string_literal: true

require "uri"

module News
  # Internal metadata contract, not a vendor response schema. No article bodies.
  Item = Data.define(:provider_item_id, :source, :title, :url, :published_at, :kind, :entities) do
    def initialize(provider_item_id:, source:, title:, url:, published_at:, kind:, entities:)
      fields = { provider_item_id: [ provider_item_id, 200 ], source: [ source, 200 ], title: [ title, 500 ], url: [ url, 2048 ] }
      fields.each do |name, (value, maximum)|
        unless value.is_a?(String) && value.valid_encoding? && value.strip.present? && value.length <= maximum && !value.match?(/[[:cntrl:]]/)
          raise Provider::InvalidResponse, "Invalid news #{name}"
        end
      end
      unless %w[news press_release other].include?(kind) &&
             (published_at.is_a?(Time) || published_at.is_a?(ActiveSupport::TimeWithZone))
        raise Provider::InvalidResponse, "Invalid news kind or publication timestamp"
      end
      unless entities.is_a?(Array) && entities.size.between?(1, 20) && entities.all? { |entity| entity.is_a?(Entity) } && entities.uniq.size == entities.size
        raise Provider::InvalidResponse, "Expected 1 to 20 distinct canonical news entities"
      end
      uri = URI.parse(url)
      unless uri.is_a?(URI::HTTPS) && uri.host.present? && uri.userinfo.nil?
        raise Provider::InvalidResponse, "News URL must be an absolute HTTPS link without credentials"
      end

      super(provider_item_id: provider_item_id.dup.freeze, source: source.dup.freeze,
            title: title.dup.freeze, url: url.dup.freeze, published_at: published_at.to_time.getutc.floor(6),
            kind: kind.dup.freeze, entities: entities.dup.freeze)
    rescue URI::InvalidURIError
      raise Provider::InvalidResponse, "Invalid news URL"
    end

    def content
      to_h.except(:provider_item_id, :entities)
    end

    def suppression_reason
      return "restricted_language" if Policy::BannedLanguageScan.new.scan_text("#{source}\n#{title}").any?
      "markup" if source.match?(/[<>]/) || title.match?(/[<>]/)
    end
  end
end
