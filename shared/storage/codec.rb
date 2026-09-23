# frozen_string_literal: true

require "json"

module PhronomyExamples
  module Storage
    # The envelope is durable; its payload remains opaque to this driver.
    module Codec
      module_function

      def dump(record)
        JSON.generate("record_type" => record.record_type,
          "format_version" => record.format_version, "payload" => record.payload)
      rescue JSON::GeneratorError, TypeError => error
        raise Phronomy::Storage::SerializationError, error.message
      end

      def load(json)
        value = JSON.parse(json)
        raise Phronomy::Storage::SerializationError, "record envelope must be an object" unless value.is_a?(Hash)
        Phronomy::Storage::DurableRecord.new(record_type: value.fetch("record_type"),
          format_version: value.fetch("format_version"), payload: value.fetch("payload"))
      rescue JSON::ParserError, KeyError, ArgumentError, TypeError => error
        raise Phronomy::Storage::SerializationError, error.message
      end
    end
  end
end
