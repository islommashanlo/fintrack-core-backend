# frozen_string_literal: true

namespace :api do
  desc "Validate local OpenAPI structure and API route coverage without external requests"
  task validate_contract: :environment do
    result = ApiContract::Check.new.call
    abort result.errors.join("\n") unless result.errors.empty?

    puts "API contract valid: #{result.operation_count} operations; route coverage, references, operation IDs and path parameters checked."
  end
end
