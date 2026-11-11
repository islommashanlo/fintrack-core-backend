# Billing fixtures

These are synthetic test identifiers and data, based on Stripe's documented
[subscription response](https://docs.stripe.com/api/subscriptions/retrieve) and
[event envelope](https://docs.stripe.com/api/events/object). No customer,
subscription, payment or Stripe test account was created to obtain them.

The tested API version is `2026-10-28.endive`. The fixture uses item-level billing
periods, as described in Stripe's [period-field migration](https://docs.stripe.com/changelog/basil/2025-03-31/deprecate-subscription-current-period-start-and-end).
The support helper sets period timestamps relative to each test's clock and wraps
this object in synthetic events. Delivery signatures are generated locally.
Provider GETs are mocked with WebMock; every unstubbed HTTP request is blocked.
