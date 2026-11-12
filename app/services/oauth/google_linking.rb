# frozen_string_literal: true

module Oauth
  class GoogleLinking
    class Unavailable < StandardError; end
    class Invalid < StandardError; end
    class Conflict < StandardError; end

    def self.client_id
      value = ENV["GOOGLE_OAUTH_CLIENT_ID"].to_s
      value if value.match?(/\A[A-Za-z0-9_-]{1,200}\.apps\.googleusercontent\.com\z/)
    end

    def self.enabled?
      ENV["OAUTH_GOOGLE_LINKING"] == "on" && client_id.present?
    end

    def self.require_enabled!
      raise Unavailable unless enabled?
    end

    def self.start(user:, session:, current_password:)
      require_enabled!
      OauthLinkIntents.issue(user:, session:, current_password:)
    end

    def self.complete(user:, session:, state:, id_token:)
      require_enabled!
      raise Invalid unless state.is_a?(String) && state.match?(/\A[A-Za-z0-9_-]{43}\z/)
      pending = OauthLinkIntent.joins(:session).where(session_id: session.id, sessions: { user_id: user.id },
        state_digest: Digest::SHA256.hexdigest(state), consumed_at: nil)
        .where("expires_at > ? AND sessions.created_at > ?", Time.current, Time.current - Session::LIFETIME).exists?
      raise Invalid unless pending

      expected_client = client_id
      claims = GoogleTokenVerifier.verify(id_token, client_id: expected_client)
      user.with_lock do
        require_enabled!
        raise Unavailable unless client_id == expected_client
        OauthLinkIntents.consume(user:, session:, state:, nonce: claims.fetch(:nonce))
        record = OauthIdentity.find_by(provider: "google", subject: claims.fetch(:subject))
        raise Conflict if record && record.user_id != user.id
        current = user.oauth_identities.find_by(provider: "google")
        raise Conflict if current && current.subject != claims.fetch(:subject)
        record ||= user.oauth_identities.create!(provider: "google", subject: claims.fetch(:subject))
        yield record if block_given?
        record
      end
    rescue OauthLinkIntents::Invalid
      raise Invalid
    rescue ActiveRecord::RecordNotUnique
      raise Conflict
    rescue ActiveRecord::RecordInvalid => error
      raise unless error.record.is_a?(OauthIdentity) && error.record.errors.details.values.flatten.any? { |detail| detail[:error] == :taken }

      raise Conflict
    end
  end
end
