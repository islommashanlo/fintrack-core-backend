# frozen_string_literal: true

require "rails_helper"

RSpec.describe Policy::BannedLanguageScan do
  it "recognizes banned recommendation terms and phrases" do
    violations = described_class.new.scan_text("Buy this stock; Strong Buy; bullish opportunity", path: "test.txt")

    expect(violations.map(&:line)).to all(eq(1))
    expect(violations.first.text).to include("Buy this stock")
  end

  it "allows factual transaction language" do
    violations = described_class.new.scan_text("Reported a purchase and a sale; activity is unusual", path: "test.txt")

    expect(violations).to be_empty
  end

  it "passes the policy-scanned repository paths" do
    expect(described_class.new.violations).to be_empty
  end
end
