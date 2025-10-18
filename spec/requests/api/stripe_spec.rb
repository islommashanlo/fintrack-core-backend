require 'rails_helper'

RSpec.describe "Api::Stripes", type: :request do
  describe "GET /webhooks" do
    it "returns http success" do
      get "/api/stripe/webhooks"
      expect(response).to have_http_status(:success)
    end
  end

end
