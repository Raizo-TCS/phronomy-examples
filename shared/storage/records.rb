# frozen_string_literal: true

# Compatibility import; implementation lives in the optional package.
require "phronomy/active_record"

module PhronomyExamples
  Storage = PhronomyActiveRecord::Storage unless const_defined?(:Storage, false)
end
