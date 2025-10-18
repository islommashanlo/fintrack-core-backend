# frozen_string_literal: true

class Api::AlertPreferencesController < ApplicationController
  before_action :authenticate_user!

  # GET /api/alert_preferences
  def index
    preferences = current_user.alert_preferences.includes(:user)
    render json: preferences.as_json(
      only: %i[id ticker source_type person_name active created_at updated_at]
    )
  end

  # POST /api/alert_preferences
  def create
    preference = current_user.alert_preferences.new(preference_params)

    if preference.save
      render json: preference.as_json(
        only: %i[id ticker source_type person_name active created_at updated_at]
      ), status: :created
    else
      render json: { errors: preference.errors.full_messages }, status: :unprocessable_entity
    end
  end

  # GET /api/alert_preferences/:id
  def show
    preference = current_user.alert_preferences.find(params[:id])
    render json: preference.as_json(
      only: %i[id ticker source_type person_name active created_at updated_at]
    )
  end

  # PUT/PATCH /api/alert_preferences/:id
  def update
    preference = current_user.alert_preferences.find(params[:id])

    if preference.update(preference_params)
      render json: preference.as_json(
        only: %i[id ticker source_type person_name active created_at updated_at]
      )
    else
      render json: { errors: preference.errors.full_messages }, status: :unprocessable_entity
    end
  end

  # DELETE /api/alert_preferences/:id
  def destroy
    preference = current_user.alert_preferences.find(params[:id])
    preference.destroy

    render json: { message: 'Alert preference deleted successfully' }
  end

  private

  def preference_params
    params.require(:alert_preference).permit(:ticker, :source_type, :person_name, :active)
  end
end
