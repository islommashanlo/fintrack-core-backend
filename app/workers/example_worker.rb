# frozen_string_literal: true

class ExampleWorker
  include Sidekiq::Worker

  def perform(message = 'hello')
    Rails.logger.info({ worker: 'ExampleWorker', message: message }.to_json)
  end
end
