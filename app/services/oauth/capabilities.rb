# frozen_string_literal: true

module Oauth
  class Capabilities
    def self.call
      paths = Rails.application.routes.url_helpers
      {
        google: {
          availability: "configuration_only", account_creation: false, email_matching: false,
          sign_in: {
            signed_out_required: true, linked_accounts_only: true,
            flows: {
              id_token: flow(enabled: GoogleSignIn.enabled?, start_path: paths.api_v1_google_sign_in_start_path,
                complete_path: paths.api_v1_google_sign_in_complete_path),
              authorization_code: flow(enabled: GoogleCodeFlow.enabled?(flow: "sign_in"), start_path: paths.api_v1_google_authorize_path,
                complete_path: paths.api_v1_google_callback_path, complete_method: "GET")
            }
          },
          linking: {
            authentication_required: true, current_password_required: true,
            flows: {
              id_token: flow(enabled: GoogleLinking.enabled?, start_path: paths.api_v1_oauth_link_start_path,
                complete_path: paths.api_v1_oauth_link_complete_path),
              authorization_code: flow(enabled: GoogleCodeFlow.enabled?(flow: "link"), start_path: paths.api_v1_oauth_link_authorize_path,
                complete_path: paths.api_v1_oauth_link_callback_path, complete_method: "GET")
            }
          }
        }
      }
    end

    def self.flow(enabled:, start_path:, complete_path:, complete_method: "POST")
      { enabled:, start: { method: "POST", path: start_path }, complete: { method: complete_method, path: complete_path } }
    end
    private_class_method :flow
  end
end
