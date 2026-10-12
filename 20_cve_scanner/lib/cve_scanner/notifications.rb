# frozen_string_literal: true

require "phronomy/integrations/ordered_event_delivery"

module CveScanner
  # Application-owned routing and error messages. M91 owns the delivery queue,
  # payload snapshots, worker, ordering and drain; it knows nothing about Rails.
  module Notifications
    module_function

    def open(scan_id:)
      # Resolve Rails dependencies on the calling Job/request, before delivery.
      channel = ScanChannel
      executor = Rails.application.executor
      deliver = ->(payload) {
        executor.wrap { channel.broadcast(scan_id, payload) }
      }

      Phronomy::Integrations::OrderedEventDelivery.open(
        deliver: deliver, capacity: 256, batch_size: 32, flush_timeout: 30
      ) do |delivery|
        begin
          yield delivery
        rescue StandardError => primary
          report_failure(delivery, primary)
          raise
        end
      end
    end

    def report_failure(delivery, primary)
      delivery.publish(type: "error", message: primary.message)
    rescue StandardError => secondary
      begin
        Rails.logger.error("Scan notification failed: #{secondary.class}: #{secondary.message}")
      rescue StandardError
        # Preserve the original application failure, even if reporting fails.
      end
    end
    private_class_method :report_failure
  end
end
