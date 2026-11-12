# frozen_string_literal: true

module ApiContract
  class Check
    Result = Data.define(:errors, :operation_count)

    def initialize(path: Rails.root.join("docs/openapi.yml"), routes: Rails.application.routes.routes,
                   export_datasets: Api::V1::ExportQuery::PARAMETERS.keys)
      @path, @routes, @export_datasets = path, routes, export_datasets
    end

    def call
      document = Document.new(File.read(@path))
      errors = document.errors.dup
      if errors.empty?
        actual = RouteInventory.new(routes: @routes, export_datasets: @export_datasets).operations
        errors.concat((actual - document.operations).map { |operation| "Undocumented route: #{operation}" })
        errors.concat((document.operations - actual).map { |operation| "Unrouted operation: #{operation}" })
      end
      Result.new(errors: errors.uniq, operation_count: document.operations.size)
    rescue Errno::ENOENT
      Result.new(errors: [ "OpenAPI file not found: #{@path}" ], operation_count: 0)
    end
  end
end
