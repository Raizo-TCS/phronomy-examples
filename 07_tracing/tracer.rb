# frozen_string_literal: true

require "ostruct"
require "phronomy"

# Minimal tracer that prints span lifecycle events to stdout.
class ConsoleTracer < Phronomy::Tracing::Base
  def start_span(name, input: nil, **_meta)
    puts "[SPAN START] #{name.to_s.ljust(16)} input=#{input.inspect}"
    OpenStruct.new(name: name, started_at: Time.now)
  end

  def finish_span(span, output: nil, error: nil)
    elapsed_ms = ((Time.now - span.started_at) * 1000).to_i
    suffix = error ? " error=#{error.class}: #{error.message}" : ""
    puts "[SPAN END]   #{span.name.to_s.ljust(16)} elapsed=#{elapsed_ms}ms#{suffix}"
    _ = output
  end
end
