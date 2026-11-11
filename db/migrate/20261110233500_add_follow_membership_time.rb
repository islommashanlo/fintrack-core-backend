# frozen_string_literal: true

class AddFollowMembershipTime < ActiveRecord::Migration[8.0]
  def up
    add_column :follows, :followed_at, :datetime
    execute "UPDATE follows SET followed_at = created_at"
    change_column_null :follows, :followed_at, false
    change_column_default :follows, :followed_at, -> { "CURRENT_TIMESTAMP" }
  end

  def down
    remove_column :follows, :followed_at
  end
end
