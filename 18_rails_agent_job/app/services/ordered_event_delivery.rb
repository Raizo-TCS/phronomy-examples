# frozen_string_literal: true

# Application-owned adapter. Uses existing Phronomy workers only while sending
# a batch. No worker waits on an empty queue. There is no durable delivery claim.
class OrderedEventDelivery
  class ClosedError < StandardError; end
  class OverflowError < StandardError; end

  def initialize(capacity: 256, batch_size: 32, &deliver)
    raise ArgumentError, "deliver block required" unless deliver
    unless capacity.is_a?(Integer) && capacity.positive? &&
        batch_size.is_a?(Integer) && batch_size.positive?
      raise ArgumentError, "capacity and batch_size must be positive Integers"
    end
    @capacity = capacity
    @batch_size = batch_size
    @deliver = deliver
    @mutex = Mutex.new
    @condition = ConditionVariable.new
    @queue = []
    @accepting = true
    @running = false
    @failure = nil
  end

  # Short, thread-safe enqueue; never waits for queue space or network I/O.
  # This adapter's explicit overload policy is failure, not silent dropping.
  def publish(payload)
    value = immutable_copy(payload)
    start_worker = @mutex.synchronize do
      raise @failure if @failure
      raise ClosedError, "event delivery closed" unless @accepting
      raise OverflowError, "event delivery queue full" if @queue.length >= @capacity
      @queue << value
      if @running
        false
      else
        @running = true
        true
      end
    end
    start_drain if start_worker
    error = @mutex.synchronize { @failure }
    raise error if error
    self
  rescue => error
    # Listener exceptions may be logged by the event source. Retain publication
    # failures so the Job's final flush fails even if the listener cannot raise
    # through Agent#stream. Already accepted work is still drained in order.
    @mutex.synchronize do
      @failure ||= error
      @accepting = false
    end
    raise error
  end

  # Called by the Rails job thread AFTER Agent#stream returns/raises.
  # A timeout stops this wait, not an already-running network operation.
  def close_and_wait(timeout: nil)
    if Phronomy::Runtime.in_event_loop_context?
      raise Phronomy::EventLoopReentrancyError, "delivery flush cannot block EventLoop"
    end
    deadline = timeout && monotonic_now + timeout
    @mutex.synchronize do
      @accepting = false
      while @running
        remaining = deadline && deadline - monotonic_now
        if remaining && remaining <= 0
          raise Phronomy::TimeoutError, "event delivery flush timed out"
        end
        @condition.wait(@mutex, remaining)
      end
      raise @failure if @failure
    end
    self
  end

  private

  def start_drain
    Phronomy::Blocking.call_async { drain }.on_complete do |_value, error|
      record_failure(error) if error
    end
  rescue => error
    record_failure(error)
  end

  def drain
    loop do
      batch = @mutex.synchronize do
        if @queue.empty?
          @running = false
          @condition.broadcast
          nil
        else
          @queue.shift(@batch_size)
        end
      end
      return nil unless batch
      coalesce_tokens(batch).each { |payload| @deliver.call(payload) }
    end
  end

  def record_failure(error)
    @mutex.synchronize do
      @failure ||= error
      @accepting = false
      @running = false
      @queue.clear
      @condition.broadcast
    end
  end

  def coalesce_tokens(batch)
    batch.each_with_object([]) do |payload, output|
      previous = output.last
      same_metadata = previous &&
        previous.except(:content) == payload.except(:content)
      if payload[:type] == "token" && same_metadata
        output[-1] = previous.merge(content: previous.fetch(:content) + payload.fetch(:content))
      else
        output << payload
      end
    end
  end

  def immutable_copy(value)
    case value
    when Hash
      value.to_h { |key, child| [immutable_copy(key), immutable_copy(child)] }.freeze
    when Array
      value.map { |child| immutable_copy(child) }.freeze
    when String
      value.dup.freeze
    when Symbol, Numeric, TrueClass, FalseClass, NilClass
      value
    else
      raise ArgumentError, "event payload must contain plain data: #{value.class}"
    end
  end

  def monotonic_now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end