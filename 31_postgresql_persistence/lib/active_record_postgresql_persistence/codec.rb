# frozen_string_literal: true

require "json"

module PhronomyExamples
  module Persistence
    class ActiveRecordPostgreSQL < Phronomy::Storage::Backend
      module Codec
        module_function

        def dump_record(record)
          unless record.is_a?(Phronomy::Storage::DurableRecord)
            raise Phronomy::Storage::SerializationError,
              "backend expected Phronomy::Storage::DurableRecord"
          end

          JSON.generate(
            "record_type" => record.record_type,
            "format_version" => record.format_version,
            "payload" => record.payload
          )
        rescue JSON::GeneratorError, TypeError => e
          raise Phronomy::Storage::SerializationError, e.message
        end

        def load_record(json)
          value = JSON.parse(json)
          Phronomy::Storage::DurableRecord.new(
            record_type: value.fetch("record_type"),
            format_version: value.fetch("format_version"),
            payload: value.fetch("payload")
          )
        rescue JSON::ParserError, KeyError, ArgumentError, TypeError => e
          raise Phronomy::Storage::SerializationError, e.message
        end
      end
    end
  end
end
