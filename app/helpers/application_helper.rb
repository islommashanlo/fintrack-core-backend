# frozen_string_literal: true

module ApplicationHelper
  def signal_date(value)
    return "—" if value.blank?

    value.to_date.strftime("%b %-d, %Y")
  end

  def signal_money(value)
    return "—" if value.blank?

    number_to_currency(value, precision: 2)
  end

  def signal_number(value)
    return "—" if value.blank?

    number_with_delimiter(value)
  end

  def signal_price(value, suspect: false)
    return "Unavailable" if value.blank?
    return "Reported" if suspect

    number_to_currency(value, precision: 2)
  end

  def signal_role(row)
    row["officer_title"].presence ||
      ("Director" if row["is_director"]) ||
      ("Officer" if row["is_officer"]) ||
      ("10% owner" if row["is_ten_percent_owner"]) ||
      "Insider"
  end

  def issuer_label(row)
    row["issuer_ticker"].presence || row["issuer_name"].presence || "Unknown issuer"
  end

  def insider_label(row)
    row["insider_name"].presence || "Unknown insider"
  end
end
