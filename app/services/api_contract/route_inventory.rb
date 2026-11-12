# frozen_string_literal: true

module ApiContract
  class RouteInventory
    def initialize(routes:, export_datasets:)
      @routes, @export_datasets = routes, export_datasets
    end

    def operations
      @routes.flat_map do |route|
        path = route.path.spec.to_s.delete_suffix("(.:format)")
        next [] unless path.start_with?("/api/v1/") || route.defaults[:controller].to_s.start_with?("api/v1/")

        paths = if path == "/api/v1/exports/:dataset"
          @export_datasets.map { |dataset| "/api/v1/exports/#{dataset}" }
        else
          [ path.gsub(/:([a-zA-Z_][a-zA-Z0-9_]*)/, '{\1}') ]
        end
        route.verb.split("|").product(paths).map { |verb, item| "#{verb} #{item}" }
      end.uniq.sort
    end
  end
end
