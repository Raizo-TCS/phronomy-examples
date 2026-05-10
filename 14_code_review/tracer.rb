# frozen_string_literal: true

require "ostruct"
require "phronomy"

# Prints span lifecycle events to stdout with elapsed time.
# Plugged into Phronomy.configure { |c| c.tracer = ConsoleTracer.new }.
class ConsoleTracer < Phronomy::Tracing::Base
  def start_span(name, input: nil, **_meta)
    OpenStruct.new(name: name, started_at: Time.now)
  end

  def finish_span(span, output: nil, usage: nil, error: nil)
    elapsed_ms = ((Time.now - span.started_at) * 1000).to_i
    suffix = error ? "  ERROR=#{error.class}: #{error.message}" : ""
    puts "[SPAN] #{span.name.to_s.ljust(22)} elapsed=#{elapsed_ms}ms#{suffix}"
  end
end
