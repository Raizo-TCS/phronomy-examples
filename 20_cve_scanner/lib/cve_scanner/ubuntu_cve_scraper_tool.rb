# frozen_string_literal: true

require "net/http"
require "uri"
require "nokogiri"

# Tool: fetches and parses the Ubuntu security page for a given CVE ID.
# Returns a JSON string with priority, description, and affected packages.
class CveScanner::UbuntuCveScraperTool < Phronomy::Tool::Base
  description "Fetch CVE details from the Ubuntu security tracker page"

  param :cve_id, type: :string, desc: "CVE ID (e.g. CVE-2024-1234)"

  def execute(cve_id:)
    uri = URI.parse("https://ubuntu.com/security/#{cve_id}")
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, read_timeout: 20) do |http|
      http.get(uri.path)
    end

    unless response.is_a?(Net::HTTPSuccess)
      return "error=Could not fetch #{cve_id} (HTTP #{response.code})"
    end

    doc = Nokogiri::HTML(response.body)

    # Priority
    priority_el = doc.at_css(".p-heading--5, [data-label='Priority'] td, .cve-status")
    priority = priority_el&.text&.strip || "unknown"

    # Full description (the <h2>Description</h2> section paragraph)
    description = ""
    doc.css("h2").each do |h2|
      next unless h2.text.strip == "Description"
      parent = h2.parent
      p_el = parent.at_css("p")
      description = p_el&.text&.gsub(/\s+/, " ")&.strip || ""
    end
    description = doc.at_css("main p")&.text&.strip&.slice(0, 500) || "no description" if description.empty?

    # Ubuntu security team notes (under <h2>Notes</h2>)
    notes = []
    doc.css("h2").each do |h2|
      next unless h2.text.strip == "Notes"
      parent = h2.parent
      parent.css("h3").each do |author|
        # Following sibling paragraphs/text nodes are the note content
        author_name = author.text.strip
        content_parts = []
        node = author.next_sibling
        while node
          break if node.name == "h3"
          t = node.text.gsub(/\s+/, " ").strip
          content_parts << t if t.length > 3
          node = node.next_sibling
        end
        notes << "#{author_name}: #{content_parts.join(" ")}" unless content_parts.empty?
      end
      # fallback: grab all text if no h3 found
      if notes.empty?
        text = parent.text.gsub(/\s+/, " ").strip
        text = text.sub(/\ANote[s]?\s*/i, "").strip
        notes << text unless text.empty?
      end
    end

    # References
    references = []
    doc.css("h2").each do |h2|
      next unless h2.text.strip == "References"
      parent = h2.parent
      parent.css("a[href]").each do |a|
        href = a["href"].to_s.strip
        references << href if href.start_with?("http") && !references.include?(href)
      end
    end

    # Affected packages: table rows where <th> contains a valid package name.
    # Package name appears once in <th rowspan="N">; subsequent rows for the
    # same package have no <th>. Track current_package across rows.
    packages = {}
    current_package = nil
    doc.css("table tbody tr").each do |row|
      th_text = row.at_css("th")&.text&.strip
      # Skip CVSS / metadata rows (th values like "Base score", "Attack vector"…)
      if th_text && th_text.match?(/\A[a-z0-9][a-z0-9.+\-]+\z/)
        current_package = th_text
      end
      next unless current_package

      tds = row.css("td").map { |c| c.text.gsub(/\s+/, " ").strip }
      # Expect: tds[0] = "24.04 LTS noble", tds[1] = "Vulnerable, fix deferred"
      next if tds.size < 2

      series_raw   = tds[0]
      pkg_status   = tds[1]
      fix_version  = tds[2] || ""

      # Extract codename (last word of series_raw)
      series = series_raw.split(/\s+/).last || series_raw

      packages[current_package] ||= {}
      packages[current_package][series] = {status: pkg_status, fix_version: fix_version}
    end

    result = {
      cve_id: cve_id,
      priority: priority,
      description: description,
      notes: notes,
      references: references.first(10),
      packages: packages
    }

    require "json"
    result.to_json
  rescue StandardError => e
    "error=#{e.message}"
  end
end
