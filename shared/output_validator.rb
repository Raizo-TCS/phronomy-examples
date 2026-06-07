# frozen_string_literal: true

# Shared helper for validating LLM outputs in example scripts.
#
# Provides a retry-aware assertion mechanism: when an LLM output does not meet
# the expectation, the block is re-executed up to MAX_RETRIES more times before
# giving up and exiting with status 1.
#
# Usage:
#
#   result = validate("agent produces a greeting") do
#     MyAgent.new.invoke("Say hello")
#   end
#   # result is the last return value of the block when validation passes
#
#   # With a custom check:
#   validate("agent mentions Tokyo", check: ->(r) { r[:output].include?("Tokyo") }) do
#     CityAgent.new.invoke("Tell me about Tokyo")
#   end
#
# Default check: result[:output] (or result.output for WorkflowContext) is a
# non-empty string with at least MIN_OUTPUT_CHARS characters.
#
module OutputValidator
  MAX_RETRIES = 3
  MIN_OUTPUT_CHARS = 20

  # Extracts the output string from various return shapes.
  def self.extract_output(result)
    case result
    when Hash then result[:output].to_s
    when String then result
    else
      result.respond_to?(:output) ? result.output.to_s : result.to_s
    end
  end

  # Runs the block up to MAX_RETRIES+1 times until the check passes.
  # Exits the process with status 1 if all attempts fail.
  #
  # @param label [String] human-readable description printed on failure
  # @param check [Proc, nil] custom validator; receives the block return value,
  #   must return truthy to pass. Defaults to checking minimum output length.
  # @param min_chars [Integer] minimum output length for the default check
  # @yield the block that invokes the LLM and returns a result
  # @return the block's return value on success
  def self.validate(label, check: nil, min_chars: MIN_OUTPUT_CHARS)
    attempts = MAX_RETRIES + 1
    last_result = nil
    last_reason = nil

    attempts.times do |i|
      result = yield
      output = extract_output(result)

      passed = if check
        check.call(result)
      else
        output.length >= min_chars
      end

      if passed
        puts "[validate] OK (attempt #{i + 1}): #{label}" if i > 0
        return result
      end

      last_result = result
      last_reason = check ? "custom check failed" : "output too short (#{output.length} < #{min_chars} chars)"
      $stderr.puts "[validate] Attempt #{i + 1}/#{attempts} FAILED — #{label}: #{last_reason}"
      $stderr.puts "[validate] Output was: #{output[0, 200].inspect}" unless output.empty?
    end

    $stderr.puts "[validate] All #{attempts} attempts failed — #{label}"
    $stderr.puts "[validate] Last output: #{extract_output(last_result)[0, 400].inspect}"
    exit 1
  end
end
