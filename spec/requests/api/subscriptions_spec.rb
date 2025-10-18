require 'rails_helper'

RSpec.describe "Api::Subscriptions", type: :request do
  describe "GET /index" do
    it "returns http success" do
      get "/api/subscriptions/index"
      expect(response).to have_http_status(:success)
    end
  end

  describe "GET /create" do
    it "returns http success" do
      get "/api/subscriptions/create"
      expect(response).to have_http_status(:success)
    end
  end

  describe "GET /show" do
    it "returns http success" do
      get "/api/subscriptions/show"
      expect(response).to have_http_status(:success)
    end
  end

  describe "GET /update" do
    it "returns http success" do
      get "/api/subscriptions/update"
      expect(response).to have_http_status(:success)
    end
  end

  describe "GET /destroy" do
    it "returns http success" do
      get "/api/subscriptions/destroy"
      expect(response).to have_http_status(:success)
    end
  end

end
