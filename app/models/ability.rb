# frozen_string_literal: true

class Ability
  include CanCan::Ability

  def initialize(user)
    user ||= User.new # guest user (not logged in)

    if user.admin?
      can :manage, :all
    else
      # Regular users can read public data
      can :read, Trade
      can :read, Trader

      # Users can manage their own alert subscriptions
      can :manage, AlertSubscription, user_id: user.id

      # Users can read their own profile
      can :read, User, id: user.id

      # Users cannot access admin functionality
      cannot :access, :rails_admin
      cannot :manage, User
    end
  end
end
