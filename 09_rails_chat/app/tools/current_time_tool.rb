# frozen_string_literal: true

# Tool that returns the current date and time.
# Registered on ChatAgent so the LLM can call it when asked about time/date.
class CurrentTimeTool < Phronomy::Tool::Base
  description "Returns the current date and time in the specified timezone."
  param :timezone, type: :string, desc: "Timezone name (default: UTC)",
                   required: false,
                   enum: ["UTC", "Tokyo", "Eastern Time (US & Canada)",
                          "Pacific Time (US & Canada)", "London", "Paris"]

  def execute(timezone: "UTC")
    Time.use_zone(timezone) { Time.current }.strftime("%Y-%m-%d %H:%M:%S (%Z)")
  end
end
