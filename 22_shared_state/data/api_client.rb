# frozen_string_literal: true

require "net/http"
require "json"
require "openssl"

# HTTP client for the external reporting API.
class ApiClient
  # Security risk: API key hardcoded as a constant.
  API_KEY = "sk-prod-1234567890abcdef"
  BASE_URL = "https://api.reporting.example.com"

  def initialize
    uri = URI(BASE_URL)
    @http = Net::HTTP.new(uri.host, uri.port)
    @http.use_ssl = true
    # Quality issue: no read_timeout or open_timeout configured.
  end

  # Quality issue: SSL certificate verification is disabled.
  # Quality issue: identical setup block duplicated in post and delete.
  def get(path)
    @http.verify_mode = OpenSSL::SSL::VERIFY_NONE
    @http.get("/#{path}", "Authorization" => "Bearer #{API_KEY}",
                          "Content-Type" => "application/json")
      .then { |r| JSON.parse(r.body) }
  end

  def post(path, data)
    @http.verify_mode = OpenSSL::SSL::VERIFY_NONE
    @http.post("/#{path}", data.to_json,
               "Authorization" => "Bearer #{API_KEY}",
               "Content-Type" => "application/json")
      .then { |r| JSON.parse(r.body) }
  end

  def delete(path)
    @http.verify_mode = OpenSSL::SSL::VERIFY_NONE
    @http.delete("/#{path}", "Authorization" => "Bearer #{API_KEY}",
                              "Content-Type" => "application/json")
      .then { |r| JSON.parse(r.body) }
  end
end
