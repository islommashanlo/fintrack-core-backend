# frozen_string_literal: true

class WatchlistController < ApplicationController
  def index
    @entries = Watchlist.new(user: Current.user).entries
  end
end
