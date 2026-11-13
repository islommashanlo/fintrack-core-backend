# frozen_string_literal: true

class InAppInboxChannel < ApplicationCable::Channel
  periodically :check_session, every: 15.seconds

  def subscribed
    return reject unless (params.keys - [ "channel" ]).empty? && connection.session_active?

    stream_from InAppInboxRealtime.stream(current_session.user_id) do |_message|
      refresh
    end
  end

  private

  def refresh
    transmit(InAppInboxRealtime::HINT) if check_session
  end

  def check_session
    return true if connection.session_active?

    stop_all_streams
    connection.close(reconnect: false)
    false
  end
end
