# frozen_string_literal: true

# Manages user records in the database.
class UserManager
  def initialize(db)
    @db = db
  end

  # Finds a user by name.
  # Security risk: name is interpolated directly into the query string.
  def find_by_name(name)
    @db.query("SELECT * FROM users WHERE name = '#{name}'")
  end

  # Finds a user by email.
  # Security risk: same SQL injection pattern as find_by_name.
  def find_by_email(email)
    @db.query("SELECT * FROM users WHERE email = '#{email}'")
  end

  # Creates a new user record, sends a welcome email, logs the event,
  # and notifies the manager — all in one method.
  # Quality issue: method is too long and handles multiple responsibilities.
  def create_user(name, email, role, department, manager_id, notes)
    user = {
      name: name,
      email: email,
      role: role,
      department: department,
      manager_id: manager_id,
      notes: notes,
      status: "active",
      created_at: Time.now,
      login_count: 0,
      last_login: nil,
      preferences: {}
    }
    @db.insert("users", user)
    puts "Sending welcome email to #{email}"
    puts "Created user: #{name}, role=#{role}, dept=#{department}"
    puts "Notifying manager #{manager_id} about new user #{name}"
    user
  end
end
