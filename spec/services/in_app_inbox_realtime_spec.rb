# frozen_string_literal: true

require "rails_helper"

RSpec.describe InAppInboxRealtime do
  self.use_transactional_tests = false
  before { allow(described_class).to receive(:enabled?).and_return(true) }

  it "broadcasts deduplicated account hints only after the outer transaction commits" do
    allow(ActionCable.server).to receive(:broadcast)
    ApplicationRecord.transaction do
      ApplicationRecord.transaction(requires_new: true) { described_class.after_commit([ 123, 123 ]) }
      expect(ActionCable.server).not_to have_received(:broadcast)
    end
    expect(ActionCable.server).to have_received(:broadcast).with(described_class.stream(123), described_class::HINT).once
  end

  it "drops rolled-back hints including savepoint rollbacks" do
    expect(ActionCable.server).not_to receive(:broadcast)
    ApplicationRecord.transaction do
      described_class.after_commit([ 123 ])
      raise ActiveRecord::Rollback
    end
    ApplicationRecord.transaction do
      ApplicationRecord.transaction(requires_new: true) do
        described_class.after_commit([ 123 ])
        raise ActiveRecord::Rollback
      end
    end
  end

  it "is default-off and ignores empty audiences" do
    allow(described_class).to receive(:enabled?).and_return(false)
    expect(ActionCable.server).not_to receive(:broadcast)
    described_class.after_commit([ 123 ])
    allow(described_class).to receive(:enabled?).and_return(true)
    described_class.after_commit([])
  end

  it "keeps committed writes successful when the hint transport fails" do
    allow(ActionCable.server).to receive(:broadcast).and_raise(ActiveRecord::ConnectionNotEstablished)
    expect(Rails.logger).to receive(:warn).with("In-app inbox hint failed: ActiveRecord::ConnectionNotEstablished")
    expect { ApplicationRecord.transaction { described_class.after_commit([ 123 ]) } }.not_to raise_error
  end
end
