# frozen_string_literal: true

Rails.application.config.middleware.insert_before 0, Rack::Cors do
  allow do
    origins ENV.fetch('ALLOWED_ORIGINS', 'http://localhost:3000, http://localhost:5173').split(/\s*,\s*/)
    resource '*', headers: :any, methods: %i[get post put patch delete options head], credentials: true
  end
end
