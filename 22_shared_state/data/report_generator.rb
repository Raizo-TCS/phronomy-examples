# frozen_string_literal: true

# Generates periodic reports from a dataset.
class ReportGenerator
  # Quality issue: filtering, sorting, and slicing logic is identical in all
  # three generate_* methods — a clear case of copy-paste duplication.

  def generate_monthly(records)
    active = records.select { |r| r[:status] == "active" }
    sorted = active.sort_by { |r| r[:created_at] }
    # Quality issue: magic number 500 with no explanation.
    sorted.first(500).map { |r| "#{r[:id]},#{r[:name]},#{r[:created_at]}" }.join("\n")
  end

  def generate_weekly(records)
    active = records.select { |r| r[:status] == "active" }
    sorted = active.sort_by { |r| r[:created_at] }
    sorted.first(500).map { |r| "#{r[:id]},#{r[:name]},#{r[:created_at]}" }.join("\n")
  end

  def generate_daily(records)
    active = records.select { |r| r[:status] == "active" }
    sorted = active.sort_by { |r| r[:created_at] }
    sorted.first(500).map { |r| "#{r[:id]},#{r[:name]},#{r[:created_at]}" }.join("\n")
  end

  # Returns one page of results.
  # Quality issue: magic number 25 (page size) hardcoded with no constant.
  def paginate(results, page)
    results.each_slice(25).to_a[page] || []
  end
end
