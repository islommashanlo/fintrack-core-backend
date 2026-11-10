# frozen_string_literal: true

module Api
  module V1
    class UserSerializer
      def self.render(user)
        plan = PlanCatalog.for_user(user)
        { id: user.id, email: user.email_address, created_at: user.created_at,
          plan:, limits: PlanCatalog::PLANS.fetch(plan) }
      end
    end
  end
end
