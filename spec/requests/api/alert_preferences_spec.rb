require 'rails_helper'

RSpec.describe "Api::AlertPreferences", type: :request do
  describe "GET /index" do
    it "returns http success" do
      get "/api/alert_preferences/index"
      expect(response).to have_http_status(:success)
    end
  end

  describe "GET /create" do
    it "returns http success" do
      get "/api/alert_preferences/create"
      expect(response).to have_http_status(:success)
    end
  end

  describe "GET /show" do
    it "returns http success" do
      get "/api/alert_preferences/show"
      expect(response).to have_http_status(:success)
    end
  end

  describe "GET /update" do
    it "returns http success" do
      get "/api/alert_preferences/update"
      expect(response).to have_http_status(:success)
    end
  end

  describe "GET /destroy" do
    it "returns http success" do
      get "/api/alert_preferences/destroy"
      expect(response).to have_http_status(:success)
    end
  end

end
