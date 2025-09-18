class HealthController < ApplicationController
  def index
    render json: { message: "FinTrack Rails API running" }
  end

  def health
    render json: { status: "healthy", timestamp: Time.now.to_i }
  end
end


