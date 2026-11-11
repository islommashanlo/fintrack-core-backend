# frozen_string_literal: true

module Billing
  class HostedSessions
    class Conflict < StandardError
      attr_reader :code
      def initialize(code)
        @code = code
        super("Billing operation requires resolution")
      end
    end

    def self.checkout(user:, interval:, request_id:, client: StripeClient.new)
      Configuration.require_webhooks!
      price = Configuration.checkout_prices[interval]
      raise Configuration::Unavailable unless price

      callback = Configuration.return_url
      # Commit intent before any provider side effect, retaining the retry deadline.
      attempt = user.with_lock do
        existing = user.billing_checkouts.find_by(request_id:, livemode: live?)
        existing ||= user.billing_checkouts.where(livemode: live?, status: %w[pending open needs_review]).order(:id).first
        if existing
          raise Conflict.new("CHECKOUT_CONFLICT") unless existing.interval == interval && existing.price_id == price
          existing
        else
          ensure_no_subscription!(user, user.billing_customers.find_by(livemode: live?))
          user.billing_checkouts.create!(request_id:, interval:, price_id: price, livemode: live?,
            success_url: "#{callback}?checkout=success", cancel_url: "#{callback}?checkout=canceled")
        end
      end
      error = nil
      result = user.with_lock do
        attempt.reload
        begin
          raise Conflict.new("CHECKOUT_REVIEW_REQUIRED") if attempt.status == "needs_review"
          raise Conflict.new("CHECKOUT_EXPIRED") if attempt.status == "expired"
          raise Conflict.new("CHECKOUT_PENDING_CONFIRMATION") if attempt.status == "complete"
          raise Conflict.new("CHECKOUT_REVIEW_REQUIRED") if attempt.stripe_id.nil? && attempt.created_at <= 22.hours.ago

          customer = user.billing_customers.find_by(livemode: live?)
          ensure_no_subscription!(user, customer) unless attempt.stripe_id
          unless customer
            data = client.create_customer(key: key(user, "customer", attempt.request_id))
            unless data.is_a?(Hash) && data["object"] == "customer" && data["livemode"] == live? && data["id"].is_a?(String) && data["id"].match?(/\Acus_[A-Za-z0-9_]{1,200}\z/)
              raise StripeClient::InvalidResponse
            end
            customer = CustomerLink.bind!(user:, stripe_id: data.fetch("id"), livemode: live?)
          end
          attempt.update!(billing_customer: customer)
          data = if attempt.stripe_id
            client.retrieve_checkout(attempt.stripe_id)
          else
            client.create_checkout(key: key(user, "checkout", attempt.request_id), parameters: {
              "mode" => "subscription", "customer" => customer.stripe_id, "client_reference_id" => attempt.request_id,
              "line_items[0][price]" => attempt.price_id, "line_items[0][quantity]" => 1,
              "success_url" => attempt.success_url, "cancel_url" => attempt.cancel_url
            })
          end
          validate_checkout!(data, attempt:, customer:)
          attempt.update!(stripe_id: data.fetch("id"), stripe_subscription_id: data["subscription"],
            status: data.fetch("status"), expires_at: Time.at(data.fetch("expires_at")).utc)
          raise Conflict.new("CHECKOUT_PENDING_CONFIRMATION") if attempt.status == "complete"
          raise Conflict.new("CHECKOUT_EXPIRED") if attempt.status == "expired" || attempt.expires_at <= Time.current

          { url: hosted_url!(data["url"], host: "checkout.stripe.com"), request_id: attempt.request_id, expires_at: attempt.expires_at }
        rescue CustomerLink::Conflict, Conflict, StripeClient::TransientError, StripeClient::InvalidResponse, Configuration::Unavailable => failure
          failure = StripeClient::InvalidResponse.new if failure.is_a?(CustomerLink::Conflict)
          attempt.update!(status: "needs_review") if failure.is_a?(StripeClient::InvalidResponse)
          error = failure
          nil
        end
      end
      raise error if error
      result
    end

    def self.portal(user:, request_id:, client: StripeClient.new)
      Configuration.require_webhooks!
      callback = Configuration.return_url
      user.with_lock do
        customer = user.billing_customers.find_by(livemode: live?)
        raise Conflict.new("BILLING_CUSTOMER_REQUIRED") unless customer

        data = client.create_portal(customer_id: customer.stripe_id, return_url: callback, key: key(user, "portal", request_id))
        unless data.is_a?(Hash) && data["object"] == "billing_portal.session" && data["customer"] == customer.stripe_id && data["livemode"] == live?
          raise StripeClient::InvalidResponse
        end
        { url: hosted_url!(data["url"], host: "billing.stripe.com") }
      end
    end

    def self.ensure_no_subscription!(user, customer)
      return unless customer

      if customer.subscriptions.where.not(status: Subscription::TERMINAL_STATUSES).exists?
        raise Conflict.new("BILLING_ALREADY_EXISTS")
      end
      unresolved = BillingEvent.where(stripe_customer_id: customer.stripe_id, livemode: live?, status: %w[pending failed needs_review]).exists?
      completed = user.billing_checkouts.where(livemode: live?).unresolved_completed.exists?
      if unresolved || completed
        raise Conflict.new("CHECKOUT_PENDING_CONFIRMATION")
      end
    end

    def self.validate_checkout!(data, attempt:, customer:)
      unless data.is_a?(Hash) && data["object"] == "checkout.session" && data["mode"] == "subscription" &&
          data["customer"] == customer.stripe_id && data["livemode"] == live? && data["client_reference_id"] == attempt.request_id &&
          data["id"].is_a?(String) && data["id"].match?(/\Acs_[A-Za-z0-9_]{1,200}\z/) &&
          %w[open complete expired].include?(data["status"]) && data["expires_at"].is_a?(Integer) && data["expires_at"].between?(1, 253_402_300_799) &&
          (attempt.stripe_id.nil? || attempt.stripe_id == data["id"])
        raise StripeClient::InvalidResponse
      end
      unless data["subscription"].nil? || (data["subscription"].is_a?(String) && data["subscription"].match?(/\Asub_[A-Za-z0-9_]{1,200}\z/))
        raise StripeClient::InvalidResponse
      end
    end

    def self.hosted_url!(value, host:)
      uri = URI.parse(value.to_s)
      raise StripeClient::InvalidResponse unless uri.scheme == "https" && uri.host == host && uri.port == 443 && !uri.userinfo
      value
    rescue URI::InvalidURIError
      raise StripeClient::InvalidResponse
    end

    def self.key(user, action, request_id)
      "filingsintel-#{Digest::SHA256.hexdigest([ user.id, Configuration.mode, action, request_id ].join(':'))}"
    end

    def self.live?
      Configuration.mode == "live"
    end
    private_class_method :ensure_no_subscription!, :validate_checkout!, :hosted_url!, :key, :live?
  end
end
