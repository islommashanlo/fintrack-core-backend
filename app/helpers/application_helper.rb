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

  def holding_label(row)
    row["name_of_issuer"].presence || row["cusip"].presence || "Unknown security"
  end

  def holding_detail(row)
    [ row["title_of_class"], row["cusip"] ].compact_blank.join(" · ")
  end

  def signed_signal_money(value)
    return "—" if value.blank?

    value.positive? ? "+#{signal_money(value)}" : signal_money(value)
  end

  def signed_signal_number(value)
    return "—" if value.blank?

    rendered = signal_number(value)
    value.positive? ? "+#{rendered}" : rendered
  end

  def position_change_label(value)
    value.to_s.humanize
  end

  def transaction_type_label(value)
    { "P" => "Purchase", "S" => "Sale" }.fetch(value, value.presence || "Other")
  end

  def transaction_type_class(value)
    value.to_s.downcase
  end

  def ticker_insider_label(row)
    row["insider_name"].presence || row["insider_cik"] || "Unknown insider"
  end
end
