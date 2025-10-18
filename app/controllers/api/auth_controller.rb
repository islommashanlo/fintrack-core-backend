# frozen_string_literal: true

module Api
  class AuthController < ApplicationController
    # POST /api/signup
    def signup
      user = User.new(user_params)

      if user.save
        token = user.generate_jwt_token
        render json: {
          message: 'User created successfully',
          user: user.as_json(except: %i[encrypted_password reset_password_token reset_password_sent_at
                                        remember_created_at]),
          token: token
        }, status: :created
      else
        render json: { errors: user.errors.full_messages }, status: :unprocessable_entity
      end
    end

    # POST /api/login
    def login
      user = User.find_for_database_authentication(email: params[:email])

      if user&.valid_password?(params[:password])
        token = user.generate_jwt_token
        render json: {
          message: 'Login successful',
          user: user.as_json(except: %i[encrypted_password reset_password_token reset_password_sent_at
                                        remember_created_at]),
          token: token
        }, status: :ok
      else
        render json: { error: 'Invalid email or password' }, status: :unauthorized
      end
    end

    # DELETE /api/logout
    def logout
      # In a stateless JWT implementation, logout is typically handled client-side
      # by removing the token. For server-side revocation, we'd need a token blacklist
      render json: { message: 'Logout successful' }, status: :ok
    end

    private

    def user_params
      params.require(:user).permit(:email, :password, :password_confirmation)
    end
  end
end
