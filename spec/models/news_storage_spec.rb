# frozen_string_literal: true

require "rails_helper"

RSpec.describe "News storage" do
  let(:now) { Time.utc(2026, 11, 11, 12) }
  let(:entity) { news_entity }

  def store
    News::Ingest.call(provider: "fixture", items: [ news_item(entities: [ entity ]) ], observed_at: now)
  end

  it "enforces item identity uniqueness through the database" do
    store
    expect { NewsItem.insert_all!([ NewsItem.sole.attributes.except("id") ]) }
      .to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "enforces mention identity uniqueness through the database" do
    store
    expect { NewsMention.insert_all!([ NewsMention.sole.attributes.except("id") ]) }
      .to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "rejects arbitrary polymorphic entity types through the database constraint" do
    store
    row = NewsMention.sole.attributes.except("id").merge("entity_type" => "User")
    expect { NewsMention.insert_all!([ row ]) }.to raise_error(ActiveRecord::StatementInvalid, /news_mentions_entity_role/)
  end

  it "keeps source metadata immutable and restricts deletion of referenced records" do
    store
    expect { NewsItem.sole.update!(title: "Changed") }.to raise_error(ActiveRecord::ReadonlyAttributeError)
    expect { NewsMention.sole.update!(observed_at: now + 1.day) }.to raise_error(ActiveRecord::ReadonlyAttributeError)
    expect { NewsItem.sole.destroy! }.to raise_error(ActiveRecord::DeleteRestrictionError)
    expect { Filer.find(entity.id).destroy! }.to raise_error(ActiveRecord::DeleteRestrictionError)
  end
end
