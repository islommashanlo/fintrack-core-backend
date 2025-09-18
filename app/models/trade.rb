class Trade < ApplicationRecord
  self.table_name = "trades"

  belongs_to :trader
end


