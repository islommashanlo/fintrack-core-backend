# frozen_string_literal: true

module NewsFixtures
  def news_item(entities:, index: 0, **changes)
    values = JSON.parse(Rails.root.join("spec/fixtures/news/items.json").read).fetch(index).symbolize_keys
    News::Item.new(**values.merge(published_at: Time.iso8601(values.fetch(:published_at)), entities:).merge(changes))
  end

  def news_entity(role: "issuer")
    record = if role == "fund"
      create(:institutional_filer)
    else
      create(:filer, filer_type: role == "issuer" ? "issuer" : "insider")
    end
    News::Entity.new(role:, id: record.id)
  end
end

RSpec.configure do |config|
  config.include NewsFixtures
end
