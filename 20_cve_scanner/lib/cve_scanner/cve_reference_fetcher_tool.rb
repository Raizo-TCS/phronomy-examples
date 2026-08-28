# frozen_string_literal: true

require "net/http"
require "uri"
require "nokogiri"

# Tool: fetches a CVE reference page, then uses CveReferenceSummarizerAgent to
# produce a focused summary and a list of further reference URLs found on the page.
# Only HTTPS URLs on an explicit allowlist of trusted security domains are accepted.
class CveScanner::CveReferenceFetcherTool < Phronomy::Tool::Base
  description "Fetch a security-related URL (e.g. NVD entry, upstream advisory, " \
              "mailing list thread, Launchpad bug, vendor bulletin, or any other " \
              "page relevant to a vulnerability or its remediation) and return a " \
              "concise summary from the requested perspective, plus any further " \
              "reference URLs found on the page. Use this whenever the content " \
              "of a URL would help answer a question or verify a claim about " \
              "a vulnerability, patch, or configuration guidance."

  param :url,
        type: :string,
        desc: "The reference URL to fetch (must be HTTPS)"

  param :perspective,
        type: :string,
        desc: "The aspect to focus on when summarizing the page content " \
              "(e.g. 'vulnerability', 'patch status', 'exploit availability'). " \
              "Defaults to 'vulnerability' when omitted.",
        required: false

  # Only fetch from trusted security-related domains.
  ALLOWED_DOMAINS = %w[
    nvd.nist.gov
    cve.mitre.org
    www.cve.org
    ubuntu.com
    launchpad.net
    security-tracker.debian.org
    usn.ubuntu.com
    lists.ubuntu.com
    lists.infradead.org
    github.com
    gitlab.com
    kernel.org
    www.openssl.org
    bugzilla.redhat.com
    access.redhat.com
    w1.fi
  ].freeze

  # Maximum raw characters passed to the summarizer agent.
  # Larger than a direct-return limit because the agent condenses it.
  MAX_RAW_CONTENT = 8000

  def execute(url:, perspective: "vulnerability")
    # Upgrade http:// to https:// automatically (many mailing list archives
    # are linked with http but serve over HTTPS as well).
    normalized_url = url.to_s.strip.sub(/\Ahttp:\/\//i, "https://")

    uri = begin
      URI.parse(normalized_url)
    rescue URI::InvalidURIError => e
      return "error=Invalid URL: #{e.message}"
    end

    return "error=Only HTTPS URLs are supported" unless uri.scheme == "https"

    domain = uri.host.to_s.downcase
    unless ALLOWED_DOMAINS.any? { |d| domain == d || domain.end_with?(".#{d}") }
      return "error=Domain not in allowlist: #{domain}"
    end

    response = Net::HTTP.start(
      uri.host, uri.port,
      use_ssl: true,
      read_timeout: 15,
      open_timeout: 10
    ) do |http|
      http.get(uri.request_uri, "User-Agent" => "CVE-Scanner/1.0 (security research)")
    end

    # Follow one level of redirect (common for NVD/Launchpad)
    if response.is_a?(Net::HTTPRedirection) && (location = response["location"])
      return execute(url: URI.join(normalized_url, location).to_s, perspective: perspective)
    end

    return "error=HTTP #{response.code} fetching #{normalized_url}" unless response.is_a?(Net::HTTPSuccess)

    body = response.body.encode("UTF-8", invalid: :replace, undef: :replace)

    text, further_urls = if response["content-type"].to_s.include?("text/html")
      extract_content_and_links(body, uri)
    else
      [body.gsub(/\s+/, " ").strip, []]
    end

    prompt = build_summarizer_prompt(normalized_url, text.slice(0, MAX_RAW_CONTENT), perspective, further_urls)
    CveScanner::CveReferenceSummarizerAgent.new.invoke(prompt)[:output].to_s
  rescue StandardError => e
    "error=#{e.message}"
  end

  private

  # Returns [text, further_urls] extracted from the HTML.
  # further_urls is filtered to the ALLOWED_DOMAINS allowlist.
  def extract_content_and_links(html, base_uri)
    doc = Nokogiri::HTML(html)

    # Collect absolute links before removing navigation elements
    links = doc.css("a[href]").filter_map do |a|
      href = a["href"].to_s.strip
      next if href.empty? || href.start_with?("#", "javascript:", "mailto:")

      resolved = URI.join(base_uri, href).to_s
      resolved_host = URI.parse(resolved).host.to_s.downcase
      resolved if ALLOWED_DOMAINS.any? { |d| resolved_host == d || resolved_host.end_with?(".#{d}") }
    rescue URI::InvalidURIError, URI::BadURIError
      nil
    end.uniq

    # Remove non-content elements
    doc.css("script, style, nav, footer, header, [role='navigation'], .sidebar").remove

    # Prefer main content area; fall back to body
    content_node = doc.at_css("main, article, #content, .content, #vulnDetailTableDiv") ||
                   doc.at_css("body")
    text = content_node&.text || doc.text
    text = text.gsub(/[ \t]+/, " ").gsub(/\n{3,}/, "\n\n").strip

    [text, links]
  end

  def build_summarizer_prompt(url, content, perspective, further_urls)
    further_section = further_urls.any? ? further_urls.join("\n") : "None"
    <<~PROMPT.strip
      URL: #{url}

      PAGE CONTENT:
      #{content}

      FURTHER REFERENCE URLS FOUND ON PAGE:
      #{further_section}

      PERSPECTIVE: #{perspective}
    PROMPT
  end
end
