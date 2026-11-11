# frozen_string_literal: true

module Billing
  class Recovery
    class InvalidOptions < StandardError; end
    class BudgetExceeded < StandardError; end
    Item = Data.define(:id, :status, :updated_at, :requests)
    Plan = Data.define(:kind, :mode, :cutoff, :items, :eligible_count, :review_count, :blocked_count) do
      def request_count = items.sum(&:requests)
      def to_h
        { kind:, mode: mode || "off", eligible_count:, selected_count: items.size,
          max_provider_requests: request_count, review_count:, blocked_count:, cutoff: cutoff.utc.iso8601,
          items: items.map { |item| { id: item.id, status: item.status, max_provider_requests: item.requests } } }
      end
    end

    # Only GETs are exposed; the shared counter also bounds requests after plan revalidation.
    class BudgetedClient
      attr_reader :requests

      def initialize(client, limit)
        @client, @limit, @requests = client, limit, 0
      end

      def retrieve_subscription(id) = request { @client.retrieve_subscription(id) }
      def retrieve_checkout(id) = request { @client.retrieve_checkout(id) }

      private

      def request
        raise BudgetExceeded, "Provider request budget exhausted" if @requests >= @limit
        @requests += 1
        yield
      end
    end

    def initialize(kind:, limit: 25, min_age_minutes: 10, ids: [], include_review: false, now: Time.current)
      unless %w[events checkouts].include?(kind) && limit.is_a?(Integer) && limit.between?(1, 100) &&
          min_age_minutes.is_a?(Integer) && min_age_minutes.between?(1, 10_080) &&
          ids.is_a?(Array) && ids.size <= 100 && ids.all? { |id| id.is_a?(Integer) && id.positive? } &&
          [ true, false ].include?(include_review) && (!include_review || ids.any?)
        raise InvalidOptions, "Use events/checkouts, limit 1..100, age 1..10080, and positive local IDs; review requires explicit IDs"
      end
      @kind, @limit, @ids, @include_review = kind, limit, ids.uniq.freeze, include_review
      @cutoff, @mode = now - min_age_minutes.minutes, Configuration.mode
    end

    def plan
      scope = eligible
      items = scope.order(:id).limit(@limit).map do |row|
        requests = @kind == "events" && row.event_type == "customer.subscription.deleted" ? 0 : 1
        Item.new(id: row.id, status: row.status, updated_at: row.updated_at, requests:)
      end.freeze
      review = base.where(status: "needs_review").count
      blocked = if @kind == "events"
        base.where(reason: "unmatched_customer").count
      else
        base.where(status: %w[pending open needs_review]).where(stripe_id: nil).count
      end
      Plan.new(kind: @kind, mode: @mode, cutoff: @cutoff, items:, eligible_count: scope.count,
        review_count: review, blocked_count: blocked)
    end

    def execute(plan, max_requests:, client: StripeClient.new)
      unless max_requests.is_a?(Integer) && max_requests.between?(0, 100) && plan.kind == @kind &&
          plan.mode == @mode && plan.cutoff == @cutoff
        raise InvalidOptions, "Invalid recovery plan or request budget (0..100)"
      end
      raise BudgetExceeded, "Plan exceeds the provider request budget" if plan.request_count > max_requests
      Configuration.require_webhooks!
      raise Configuration::Unavailable unless @mode && Configuration.mode == @mode

      budget = BudgetedClient.new(client, max_requests)
      results = plan.items.map { |item| recover(item, budget) }
      { provider_requests: budget.requests, results:, failed: results.any? { |row| %w[failed needs_review].include?(row.fetch(:status)) } }
    end

    private

    def base
      scope = (@kind == "events" ? BillingEvent : BillingCheckout).all
      scope = @mode ? scope.where(livemode: @mode == "live") : scope.none
      scope = scope.where(id: @ids) if @ids.any?
      scope
    end

    def eligible
      scope = base.where(updated_at: ..@cutoff)
      if @kind == "events"
        statuses = @include_review ? %w[pending failed needs_review] : %w[pending failed]
        scope.where(status: statuses, event_type: StripeEvent::TYPES, api_version: Configuration::API_VERSION)
          .where.not(verified_at: nil).where(<<~SQL.squish)
            EXISTS (SELECT 1 FROM billing_customers INNER JOIN users ON users.id = billing_customers.user_id
              WHERE billing_customers.stripe_id = billing_events.stripe_customer_id
                AND billing_customers.livemode = billing_events.livemode)
          SQL
      else
        scope = scope.where(status: %w[pending open])
          .or(scope.where(status: "complete", stripe_subscription_id: nil))
          .or(@include_review ? scope.where(status: "needs_review") : scope.none)
        scope.joins(:billing_customer, :user).where.not(stripe_id: nil)
          .where("billing_customers.user_id = billing_checkouts.user_id AND billing_customers.livemode = billing_checkouts.livemode")
      end
    end

    def recover(item, client)
      row = eligible.find_by(id: item.id)
      user = if @kind == "events"
        BillingCustomer.find_by(stripe_id: row.stripe_customer_id, livemode: row.livemode)&.user if row
      else
        row&.user
      end
      status = "skipped"
      user&.with_lock do
        next unless Configuration.mode == @mode
        row = eligible.find_by(id: item.id)
        next unless row && row.updated_at == item.updated_at

        if @kind == "events"
          # An explicit review retry still relies on the original verified receipt.
          row.update!(status: "pending", reason: nil, processed_at: nil) if row.status == "needs_review"
          begin
            ProcessEvent.call(row.id, client:)
            status = row.reload.status
          rescue StripeClient::TransientError
            status = "failed"
          end
        else
          status = RecoverCheckout.call(row, client:)
        end
      end
      { id: item.id, status: }
    rescue ActiveRecord::RecordNotFound
      { id: item.id, status: "skipped" }
    end
  end
end
