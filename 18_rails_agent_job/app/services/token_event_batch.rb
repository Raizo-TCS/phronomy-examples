# frozen_string_literal: true

# Application payload semantics: merge only adjacent tokens with equal metadata.
module TokenEventBatch
  def self.call(batch)
    batch.each_with_object([]) do |payload, output|
      previous = output.last
      same_metadata = previous && previous.except(:content) == payload.except(:content)
      if payload[:type] == "token" && same_metadata
        output[-1] = previous.merge(content: previous.fetch(:content) + payload.fetch(:content))
      else
        output << payload
      end
    end
  end
end
