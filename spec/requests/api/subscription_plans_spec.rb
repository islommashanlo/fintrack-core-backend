require 'rails_helper'

RSpec.describe "Api::SubscriptionPlans", type: :request do
  describe "GET /index" do
    it "returns http success" do
      get "/api/subscription_plans/index"
      expect(response).to have_http_status(:success)
    end
  end

end
