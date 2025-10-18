# frozen_string_literal: true

class Trader < ApplicationRecord
  self.table_name = 'traders'

  has_many :trades
end
