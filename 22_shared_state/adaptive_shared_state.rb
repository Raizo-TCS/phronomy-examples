# frozen_string_literal: true

require "json"
require "phronomy"

unless Phronomy::MultiAgent::SharedState.respond_to?(:sharing) &&
    Phronomy::Context::ContextPolicyInput.method_defined?(:with_input_token_limit) &&
    Phronomy::Context::ContextPolicy.protected_method_defined?(:estimate_tokens)
  raise Phronomy::ConfigurationError,
    "Example 22 requires the public sharing and Context budget APIs. " \
    "Install Phronomy 0.33.0 or later and update the application bundle."
end

# Each materialized lookup receives an explicit positive allowance from the
# current call's aggregate retrieval budget.
class SharedReadBudget
  attr_reader :tokens

  def update(tokens)
    @tokens = Integer(tokens)
    raise Phronomy::Context::BudgetExceededError, "No budget remains for shared information" unless @tokens.positive?
  end

  def limit!
    @tokens || raise(Phronomy::ConfigurationError, "Shared information requires a known context budget")
  end
end

# Retrieval is materialized only after the complete Tool exchange is known.
# The existing policy still selects history; original Tool results stay intact.
class AdaptiveReviewContextPolicy < Phronomy::Context::ContextPolicy
  def initialize(store:)
    @store = store
  end

  def call(input)
    window = input.input_token_limit
    unless window&.positive?
      raise Phronomy::ConfigurationError, "Adaptive review requires loaded context-window metadata"
    end

    output_reserve = window / 4
    safety_margin = window / 16
    input_limit = window - output_reserve - safety_margin
    tool_overhead = [estimate_tokens(input.tools.map(&:definition)) - input.tools.sum(&:estimated_tokens), 0].max
    selection_limit = input_limit - tool_overhead
    unless selection_limit.positive?
      raise Phronomy::Context::BudgetExceededError, "No input budget remains after Tool framing"
    end
    selection_input = input.with_input_token_limit(selection_limit)
    required_input = selection_input.with(
      knowledge: input.knowledge.select(&:required?),
      conversation: input.conversation.select { |group| group.any?(&:required?) }
    )
    required_plan = Phronomy::Context::DefaultPolicy.instance.call(required_input)
    remaining = input_limit - canonical_cost(required_plan)
    raise Phronomy::Context::BudgetExceededError, "Required input leaves no retrieval room" if remaining.negative?

    requests = retrieval_requests(required_input.conversation)
    retrieval_limit = remaining / 2
    retrieved = materialize_requests(requests, retrieval_limit)
    selection = Phronomy::Context::DefaultPolicy.instance.call(
      selection_input.with(knowledge: input.knowledge + retrieved)
    )
    if canonical_cost(selection) > input_limit
      raise Phronomy::Context::BudgetExceededError, "Selected input exceeds the adaptive input budget"
    end

    plan(instruction: selection.instruction, knowledge: selection.knowledge,
      tools: selection.tools, conversation: selection.conversation,
      metadata: selection.metadata.merge(
        "adaptive_context_window" => window,
        "reserved_output_tokens" => output_reserve,
        "safety_margin_tokens" => safety_margin,
        "adaptive_input_limit" => input_limit,
        "shared_request_count" => requests.length,
        "shared_result_budget" => retrieval_limit,
        "shared_result_tokens" => retrieved.sum(&:estimated_tokens)
      ))
  end

  private

  def canonical_cost(selection)
    items = selection.instruction + selection.knowledge + selection.conversation.flatten
    items.sum { |item| estimate_tokens(item.content) } + estimate_tokens(selection.tools.map(&:definition))
  end

  def retrieval_requests(groups)
    groups.flat_map do |group|
      calls = group.select { |item| item.kind == :assistant_message }.flat_map do |item|
        Array(item.content[:tool_calls] || item.content["tool_calls"])
      end
      names = calls.to_h { |call| [(call[:id] || call["id"]).to_s, call[:name] || call["name"]] }
      group.filter_map do |item|
        next unless item.kind == :tool_message && names[item.tool_call_id] == "read_store"

        content = item.content[:content] || item.content["content"]
        receipt = begin
          JSON.parse(content)
        rescue JSON::ParserError, TypeError
          nil
        end
        next unless receipt.is_a?(Hash) && receipt["type"] == "shared_findings_request" && receipt["version"] == 1

        {tool_call_id: item.tool_call_id, snapshot_size: receipt.fetch("snapshot_size"),
         request: receipt.fetch("request").transform_keys(&:to_sym)}
      end
    end
  end

  def materialize_requests(requests, total_limit)
    remaining = total_limit
    requests.each_with_index.map do |request, index|
      allowance = remaining / (requests.length - index)
      read_budget = SharedReadBudget.new
      read_budget.update(allowance)
      reader = AdaptiveFindingReader.new(@store, budget: read_budget, estimate: method(:estimate_tokens))
      envelope = {type: "shared_findings_page", version: 1,
                  tool_call_id: request.fetch(:tool_call_id), snapshot_size: request.fetch(:snapshot_size)}
      content = reader.read(**request.fetch(:request), snapshot_size: request.fetch(:snapshot_size),
        wrap: ->(page) { envelope.merge(page: page) }).to_json
      item = knowledge_item(content: content, required: true,
        metadata: {"shared_read_call_id" => request.fetch(:tool_call_id)})
      remaining -= item.estimated_tokens
      item
    end
  end
end

# Pages carry complete records when they fit. An oversized record has an
# explicit character cursor, so its remaining text can be retrieved losslessly.
class AdaptiveFindingReader
  def initialize(store, budget:, estimate:)
    @store = store
    @budget = budget
    @estimate = estimate
  end

  # Capture an append-only snapshot before any later Tool writes in the batch.
  def self.request(store, before_id: nil, query: nil, finding_id: nil, content_offset: 0)
    findings = store.read_all
    options = {before_id: before_id, query: query, finding_id: finding_id, content_offset: content_offset}
    validate_request!(findings, **options)
    {type: "shared_findings_request", version: 1, snapshot_size: findings.length, request: options}
  end

  def self.validate_request!(findings, before_id:, query:, finding_id:, content_offset:)
    raise ArgumentError, "before_id must be positive" if before_id && (!before_id.is_a?(Integer) || !before_id.positive?)
    raise ArgumentError, "query must be a string" if query && !query.is_a?(String)
    raise ArgumentError, "content_offset must be a nonnegative integer" unless content_offset.is_a?(Integer) && content_offset >= 0
    if finding_id
      unless finding_id.is_a?(Integer) && finding_id.between?(1, findings.length)
        raise ArgumentError, "Unknown finding ID"
      end
      unless content_offset <= findings.fetch(finding_id - 1).fetch(:content).length
        raise ArgumentError, "content_offset is outside the finding"
      end
    elsif !content_offset.zero?
      raise ArgumentError, "content_offset requires finding_id"
    end
  end

  def read(before_id: nil, query: nil, finding_id: nil, content_offset: 0, snapshot_size: nil, wrap: ->(page) { page })
    @limit = @budget.limit!
    @wrap = wrap
    findings = @store.read_all
    if snapshot_size
      unless snapshot_size.is_a?(Integer) && snapshot_size.between?(0, findings.length)
        raise ArgumentError, "Unknown shared-store snapshot"
      end
      findings = findings.first(snapshot_size)
    end
    self.class.validate_request!(findings, before_id: before_id, query: query,
      finding_id: finding_id, content_offset: content_offset)
    return @wrap.call(detail(findings, finding_id, content_offset)) if finding_id

    entries = findings.each_with_index.map { |finding, index| [index + 1, finding] }.reverse
    entries.select! { |id, _finding| id < before_id } if before_id
    if query && !query.empty?
      entries.select! { |_id, finding| finding.fetch(:content).downcase.include?(query.downcase) }
    end
    page = {total_findings: findings.length, remaining_matches: entries.length,
            next_before_id: nil, response_budget_tokens: @limit, findings: []}
    ensure_fits!(page)

    entries.each_with_index do |(id, finding), index|
      candidate = page.merge(findings: page[:findings] + [record(id, finding, 0)],
        next_before_id: (id if index + 1 < entries.length))
      if fits?(candidate)
        page = candidate
        next
      end
      break unless page[:findings].empty?

      page = fit_record(finding, 0) do |length|
        page.merge(findings: [record(id, finding, 0, length)],
          next_before_id: (id if index + 1 < entries.length))
      end
      break
    end
    @wrap.call(page)
  end

  private

  def detail(findings, finding_id, offset)
    finding = findings.fetch(finding_id - 1)
    fit_record(finding, offset) do |length|
      {finding: record(finding_id, finding, offset, length), response_budget_tokens: @limit}
    end
  end

  def record(id, finding, offset, length = nil)
    text = finding.fetch(:content)
    content = length ? text[offset, length] : text[offset..]
    following = offset + content.length
    {id: id, agent: finding.fetch(:agent), cycle: finding.fetch(:cycle),
     content: content, content_offset: offset, total_characters: text.length,
     truncated: following < text.length,
     next_content_offset: (following if following < text.length)}
  end

  def fit_record(finding, offset)
    remaining = finding.fetch(:content).length - offset
    complete = yield(remaining)
    return complete if fits?(complete)

    low = 0
    high = remaining
    while low < high
      middle = (low + high + 1) / 2
      if fits?(yield(middle))
        low = middle
      else
        high = middle - 1
      end
    end
    if low.zero?
      raise Phronomy::Context::BudgetExceededError, "Shared response metadata leaves no room for content"
    end
    result = yield(low)
    ensure_fits!(result)
    result
  end

  def fits?(value)
    @estimate.call(JSON.generate(@wrap.call(value))) <= @limit
  end

  def ensure_fits!(value)
    return if fits?(value)

    raise Phronomy::Context::BudgetExceededError, "Shared response metadata exceeds its budget"
  end
end

# The application owns the append-only record format and its invocation lifetime.
class ReviewFindingStore
  attr_reader :closed

  def initialize
    @findings = []
    @closed = false
  end

  def write(agent:, content:, cycle:)
    ensure_open!
    @findings << {agent: agent, content: content.dup.freeze, cycle: cycle}.freeze
    nil
  end

  def read_all
    ensure_open!
    @findings.dup.freeze
  end

  def size
    ensure_open!
    @findings.size
  end

  def close
    @findings.clear
    @closed = true
  end

  private

  def ensure_open!
    raise "Review findings are closed" if closed
  end
end

# One application invocation composes a store, its policies, and shared Tools.
# The framework continues to own member execution, cycles and aggregation.
class ReviewSharing
  attr_reader :store

  def initialize(store: ReviewFindingStore.new)
    @store = store
    @authors = {}
    @open_lock = Mutex.new
    @opened = false
  end

  # Derive a call-local class without changing the registered reviewer.
  def prepare_member(member)
    definition = member.agent_definition
    definitions = member.tools.to_h { |tool| [tool, member.tool_aliases[tool]] }
    prepared = member.with_tools(definitions,
      id: "#{definition.fetch(:id)}@#{definition.fetch(:version)}/adaptive-review", version: 3)
    prepared.context_policy(AdaptiveReviewContextPolicy.new(store: store))
    prepared.max_iterations(30)
    @authors[prepared] = member.name&.to_sym || definition.fetch(:id).to_sym
    prepared
  end

  def open(input:, config:)
    @open_lock.synchronize do
      raise ArgumentError, "Create a new ReviewSharing for each team invocation" if @opened
      @opened = true
    end
    begin
      yield Phronomy::MultiAgent::SharedState::Binding.new(
        store: store, tools: method(:tool_definitions)
      )
    ensure
      store.close
    end
  end

  private

  def tool_definitions(member:, cycle:)
    {build_read_tool(store) => nil,
     build_write_tool(store, cycle, @authors.fetch(member)) => nil}
  end

  def build_write_tool(store, cycle, author)
    Class.new(Phronomy::Tool::Base) do
      tool_name "write_finding"
      description "Record a new finding into the shared knowledge store so " \
                  "that other researchers can build on your discovery."
      execution_mode :cooperative
      param :content, type: :string, desc: "The finding to record"

      define_method(:execute) do |content:|
        store.write(agent: author, content: content, cycle: cycle)
        "Finding recorded."
      end
    end
  end

  def build_read_tool(store)
    Class.new(Phronomy::Tool::Base) do
      tool_name "read_store"
      description "Request shared findings from a snapshot of the store. The Tool returns a receipt; " \
                  "the next LLM input contains the matching shared_findings_page as knowledge. " \
                  "Use next_before_id for older records, query to search finding text, " \
                  "or finding_id with content_offset to retrieve one finding's text."
      execution_mode :cooperative
      param :before_id, type: :integer, required: false,
        desc: "Use the previous page's next_before_id to continue to older findings."
      param :query, type: :string, required: false,
        desc: "Optional case-insensitive substring of the complete finding text."
      param :finding_id, type: :integer, required: false,
        desc: "Stable finding ID. Returns that finding instead of a page."
      param :content_offset, type: :integer, required: false,
        desc: "Character offset within finding_id; use next_content_offset to continue."

      define_method(:execute) do |before_id: nil, query: nil, finding_id: nil, content_offset: 0|
        AdaptiveFindingReader.request(store, before_id: before_id, query: query,
          finding_id: finding_id, content_offset: content_offset).to_json
      end
    end
  end
end
