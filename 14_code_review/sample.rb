# frozen_string_literal: true

# UserRepository — sample Ruby file intentionally containing code issues
# for use with the AI Code Review Pipeline example (14_code_review).
#
# Intentional issues included for demonstration purposes:
#   Security:    SQL string interpolation (injection risk), token logged
#   Performance: N+1 query inside loop
#   Readability: overly long method, magic numbers, poor naming

class UserRepository
  def initialize(db)
    @db = db
  end

  # Finds a user by name using raw SQL string interpolation.
  # SECURITY: vulnerable to SQL injection — input is not sanitised.
  def find_by_name(name)
    sql = "SELECT * FROM users WHERE name = '#{name}'"
    @db.execute(sql).first
  end

  # Authenticates a user and logs the raw token to stdout.
  # SECURITY: secret token is exposed in plaintext logs.
  def authenticate(username, token)
    user = find_by_name(username)
    return false unless user

    puts "Authenticating #{username} with token=#{token}"
    user[:token] == token
  end

  # Returns the full profile for every user in the given list.
  # PERFORMANCE: triggers a separate SELECT for each user (N+1 query).
  def profiles_for(user_ids)
    user_ids.map do |id|
      profile = @db.execute("SELECT * FROM profiles WHERE user_id = #{id}").first
      address = @db.execute("SELECT * FROM addresses WHERE user_id = #{id}").first
      { profile: profile, address: address }
    end
  end

  # Generates a summary report for users created within a date range.
  # READABILITY: method is too long; contains magic numbers; variable x is poorly named.
  def generate_report(start_date, end_date)
    rows = @db.execute(
      "SELECT * FROM users WHERE created_at BETWEEN '#{start_date}' AND '#{end_date}'"
    )

    x = []
    rows.each do |row|
      score = 0
      score += 10 if row[:email]
      score += 20 if row[:phone]
      score += 30 if row[:address_id]
      score += 5  if row[:verified]

      tier = if score >= 60
        "gold"
      elsif score >= 35
        "silver"
      elsif score >= 15
        "bronze"
      else
        "none"
      end

      purchases = @db.execute("SELECT COUNT(*) FROM orders WHERE user_id = #{row[:id]}").first
      last_login = @db.execute("SELECT MAX(logged_at) FROM sessions WHERE user_id = #{row[:id]}").first

      x << {
        id:         row[:id],
        name:       row[:name],
        score:      score,
        tier:       tier,
        purchases:  purchases,
        last_login: last_login
      }
    end

    x.sort_by { |u| -u[:score] }
  end
end
