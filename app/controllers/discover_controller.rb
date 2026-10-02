# frozen_string_literal: true

class DiscoverController < ApplicationController
  def index
    @query = params[:q].to_s.strip
    search = DiscoverySearch.new(query: @query)

    @institutions = search.institutions(limit: 12)
    @insiders = search.insiders(limit: 12)
    @issuers = search.issuers(limit: 12)
  end
end
