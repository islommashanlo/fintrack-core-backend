# frozen_string_literal: true

require "rails_helper"
require "tempfile"

RSpec.describe ApiContract::Check do
  def route(verb, path, controller: "api/v1/things")
    Struct.new(:verb, :path, :defaults).new(verb, Struct.new(:spec).new(path), { controller: })
  end

  it "validates the committed document against real Rails routes with dispatcher and unsubscribe coverage" do
    result = described_class.new.call
    expect(result.errors).to eq([])
    expect(result.operation_count).to be_positive
    inventory = ApiContract::RouteInventory.new(routes: Rails.application.routes.routes, export_datasets: Api::V1::ExportQuery::PARAMETERS.keys).operations
    expect(inventory).to include("GET /api/v1/exports/fund-holdings", "POST /api/v1/webhooks/stripe", "GET /email/unsubscribe/{token}", "POST /email/unsubscribe/{token}")
    expect(inventory).not_to include("GET /up", "GET /sidekiq")
    expect(WebMock).not_to have_requested(:any, /./)
  end

  it "expands current export datasets, multi-verb routes and Rack routes without including HTML pages" do
    routes = [ route("GET", "/api/v1/exports/:dataset(.:format)"),
      route("GET|POST", "/email/unsubscribe/:token(.:format)"), route("POST", "/api/v1/webhooks/stripe", controller: nil),
      route("GET", "/up", controller: "rails/health"), route("GET", "/things/:id", controller: "things") ]
    result = ApiContract::RouteInventory.new(routes:, export_datasets: %w[first second]).operations
    expect(result).to eq([ "GET /api/v1/exports/first", "GET /api/v1/exports/second", "GET /email/unsubscribe/{token}",
      "POST /api/v1/webhooks/stripe", "POST /email/unsubscribe/{token}" ])
  end

  it "reports both undocumented routes and unrouted documented operations" do
    document = { "openapi" => "3.0.3", "servers" => [ { "url" => "/api/v1" } ],
      "paths" => { "/stale" => { "get" => { "operationId" => "stale", "responses" => { "200" => {} } } } } }
    Tempfile.create([ "api-contract", ".yml" ]) do |file|
      file.write(YAML.dump(document))
      file.flush
      result = described_class.new(path: file.path, routes: [ route("GET", "/api/v1/new(.:format)") ], export_datasets: []).call
      expect(result.errors).to eq([ "Undocumented route: GET /api/v1/new", "Unrouted operation: GET /api/v1/stale" ])
    end
  end

  it "reports a missing contract file" do
    result = described_class.new(path: Rails.root.join("tmp/nonexistent-openapi.yml")).call
    expect(result.errors.join).to include("OpenAPI file not found")
  end
end
