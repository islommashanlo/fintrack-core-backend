# frozen_string_literal: true

class ApplicationJob < ActiveJob::Base
  # Jobs decide for themselves what is worth retrying (invariant 6). Anything that still
  # escapes, such as the database being down, gets Sidekiq's retry, capped at three.
  sidekiq_options retry: 3 if respond_to?(:sidekiq_options)
end
