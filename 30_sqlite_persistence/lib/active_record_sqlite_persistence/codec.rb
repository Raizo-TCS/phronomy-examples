# frozen_string_literal: true

require "json"

module PhronomyExamples
  module Persistence
    class ActiveRecordSQLite < Phronomy::Persistence
      module Codec
        module_function

        def dump_domain(value)
          JSON.generate(value.to_h)
        rescue JSON::GeneratorError, TypeError => e
          raise Phronomy::Persistence::SerializationError, e.message
        end

        def load_agent_root(json)
          Phronomy::Agent::AgentRoot.from_h(JSON.parse(json))
        rescue JSON::ParserError, KeyError, ArgumentError, TypeError => e
          raise Phronomy::Persistence::SerializationError, e.message
        end

        def load_journal_record(json)
          Phronomy::Agent::JournalRecord.from_h(JSON.parse(json))
        rescue JSON::ParserError, KeyError, ArgumentError, TypeError => e
          raise Phronomy::Persistence::SerializationError, e.message
        end

        def load_execution(json)
          Phronomy::Agent::AgentExecution.from_h(JSON.parse(json))
        rescue JSON::ParserError, KeyError, ArgumentError, TypeError => e
          raise Phronomy::Persistence::SerializationError, e.message
        end

        def dump_workflow(snapshot)
          JSON.generate(normalize_workflow(snapshot))
        rescue JSON::GeneratorError, TypeError => e
          raise Phronomy::Persistence::SerializationError, e.message
        end

        def load_workflow(json)
          JSON.parse(json)
        rescue JSON::ParserError => e
          raise Phronomy::Persistence::SerializationError, e.message
        end

        def normalize_workflow(value)
          case value
          when nil, true, false, String, Integer
            value
          when Float
            unless value.finite?
              raise Phronomy::Persistence::SerializationError,
                    "Workflow state does not support non-finite Float values"
            end

            value
          when Array
            value.map { |item| normalize_workflow(item) }
          when Hash
            value.each_with_object({}) do |(key, item), normalized|
              unless key.is_a?(String) || key.is_a?(Symbol)
                raise Phronomy::Persistence::SerializationError,
                      "Workflow state Hash keys must be String or Symbol"
              end

              normalized[key.to_s] = normalize_workflow(item)
            end
          else
            raise Phronomy::Persistence::SerializationError,
                  "unsupported Workflow durable value: #{value.class}"
          end
        end
        private_class_method :normalize_workflow
      end
    end
  end
end
