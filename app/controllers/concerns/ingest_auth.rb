# frozen_string_literal: true

module IngestAuth
  extend ActiveSupport::Concern

  class Forbidden < StandardError; end

  included do
    rescue_from Forbidden do
      render json: { error: 'Forbidden' }, status: :forbidden
    end
  end

  def authenticate_ingest!
    token = request.headers['X-Ingest-Token']
    expected = ENV['INGEST_API_KEY']
    raise Forbidden, 'Missing token' if token.blank?
    raise Forbidden, 'Invalid token' unless ActiveSupport::SecurityUtils.secure_compare(token.to_s, expected.to_s)
  end
end
