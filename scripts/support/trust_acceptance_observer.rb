# frozen_string_literal: true

require "json"
require "time"
require "digest"
require "fileutils"

# Diagnostic-only observation of the pinned RubyLLM/Net::HTTP implementation.
# No provider replacement, request rewrite, timeout override or retry override.
class TrustAcceptanceObserver
  attr_reader :records

  def initialize(path:, interval: 30)
    raise ArgumentError, "Snapshot interval must be positive" unless interval.positive?
    @path, @interval = path, interval
    FileUtils.mkdir_p(File.dirname(path))
    @lock = Mutex.new
    @wake = ConditionVariable.new
    @origin = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    @records = {started_at: Time.now.utc.iso8601(6), requests: [], responses: [], http_attempts: [],
                approvals: [], decisions: [], tool_executions: 0, releases: [], results: [], exceptions: [], snapshots: [], observer_errors: []}
    # Reserve a new report rather than overwrite evidence from a previous trial.
    File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) {}
  end

  def start
    @trace = TracePoint.new(:call, :return, :raise) { |event| observe(event) }
    @trace.enable
    @watcher = Thread.new do
      Thread.current.name = "trust-acceptance-observer"
      loop do
        stop = @lock.synchronize {
          @wake.wait(@lock, @interval) unless @stopped
          @stopped
        }
        break if stop
        snapshot
      end
    end
    snapshot
  end

  def finish
    @trace&.disable
    @lock.synchronize {
      @stopped = true
      @wake.broadcast
    }
    @watcher&.join
    snapshot
  end

  def write
    @lock.synchronize { write_locked }
  end

  def exception(error)
    seen = []
    chain = []
    while error && !seen.include?(error.object_id)
      seen << error.object_id
      chain << {class: error.class.name, message: error.message, signal: error.is_a?(SignalException), backtrace: error.backtrace}
      error = error.cause
    end
    chain
  end

  private

  def record(key, value)
    @lock.synchronize do
      @records[key] << {at: Time.now.utc.iso8601(6), elapsed: elapsed, thread: Thread.current.object_id}.merge(value)
      write_locked
    end
  end

  def elapsed
    (Process.clock_gettime(Process::CLOCK_MONOTONIC) - @origin).round(3)
  end

  def snapshot
    record(:snapshots, threads: Thread.list.map { |thread| {id: thread.object_id, name: thread.name, status: thread.status, backtrace: thread.backtrace} })
  end

  def write_locked
    temporary = "#{@path}.tmp"
    File.open(temporary, "w", 0o600) { |file| file.write(JSON.pretty_generate(@records) + "\n") }
    File.rename(temporary, @path)
  end

  def observe(event)
    owner = event.defined_class.to_s
    if owner == "RubyLLM::Transport::Connection" && event.method_id == :post
      if event.event == :call
        payload = JSON.parse(JSON.generate(event.binding.local_variable_get(:payload)))
        config = event.binding.receiver.config
        settings = %i[request_timeout max_retries retry_interval retry_backoff_factor retry_interval_randomness retry_max_interval faraday_adapter]
          .to_h { |key| [key, config.public_send(key)] }
        record(:requests, path: event.binding.local_variable_get(:url), payload: payload,
          payload_sha256: Digest::SHA256.hexdigest(JSON.generate(payload)), sdk_settings: settings)
      elsif event.event == :return && (response = event.return_value).respond_to?(:body)
        record(:responses, status: response.status, body: response.body)
      end
    elsif owner == "Net::HTTP" && event.method_id == :request && event.event == :call && event.binding.receiver.started?
      # WebMock replaces this method in regression tests. Those runs are labelled
      # separately and cannot provide actual network-attempt evidence.
      return unless event.binding.local_variable_defined?(:req)
      request = event.binding.local_variable_get(:req)
      http = event.binding.receiver
      record(:http_attempts, method: request.method, path: request.path,
        open_timeout: http.open_timeout, read_timeout: http.read_timeout, write_timeout: http.write_timeout)
    elsif owner == "Phronomy::GeneratorVerifier::Approval"
      if event.method_id == :initialize && event.event == :return
        record(:approvals, value: event.binding.receiver.to_h)
      elsif event.method_id == :respond_async && event.event == :call
        record(:decisions, approved: event.binding.local_variable_get(:approved))
      end
    elsif owner == "ApprovedPolicyLookup" && event.method_id == :execute && event.event == :call
      @lock.synchronize {
        @records[:tool_executions] += 1
        write_locked
      }
    elsif event.method_id == :release! && event.event == :return && ["Phronomy::GeneratorVerifier", "Phronomy::Agent::Scope"].include?(owner)
      record(:releases, owner: owner, value: event.return_value)
    elsif owner == "Phronomy::GeneratorVerifier" && event.method_id == :build_result && event.event == :return
      record(:results, value: event.return_value.to_h)
    elsif event.event == :raise && event.raised_exception.is_a?(StandardError)
      error = event.raised_exception
      if error.class.name&.match?(/\A(?:Phronomy|RubyLLM|Faraday)::/)
        record(:exceptions, chain: exception(error))
      end
    end
  rescue => error
    # Diagnostic incompatibility must not change the observed operation's error.
    # The acceptance runner rejects an incomplete observation instead.
    @lock.synchronize { @records[:observer_errors] << {class: error.class.name, message: error.message} }
    @trace.disable
  end
end
