require "rails_helper"

RSpec.describe TradeNotificationMailer, type: :mailer do
  describe "trade_alert" do
    let(:mail) { TradeNotificationMailer.trade_alert }

    it "renders the headers" do
      expect(mail.subject).to eq("Trade alert")
      expect(mail.to).to eq(["to@example.org"])
      expect(mail.from).to eq(["from@example.com"])
    end

    it "renders the body" do
      expect(mail.body.encoded).to match("Hi")
    end
  end

end
