# frozen_string_literal: true

require 'base64'
require 'digest'
require 'fileutils'
require 'openssl'
require 'securerandom'
require 'sqlite3'

module Oxidized
  module API
    class UserStore
      attr_reader :path

      ITERATIONS = 600_000
      SESSION_IDLE_SECONDS = 8 * 60 * 60
      SESSION_ABSOLUTE_SECONDS = 12 * 60 * 60
      LOGIN_WINDOW_SECONDS = 15 * 60
      LOGIN_MAX_FAILURES = 10

      class Error < StandardError; end

      def self.default_path
        ENV['OXIDIZED_WEB_AUTH_DB'] || File.join(Dir.home, '.config', 'oxidized', 'web-auth.sqlite3')
      end

      def initialize(path = self.class.default_path)
        @path = File.expand_path(path)
        FileUtils.mkdir_p(File.dirname(@path), mode: 0o700)
        File.open(@path, File::RDWR | File::CREAT, 0o600) do |file|
          file.chmod(0o600)
        end
        File.chmod(0o600, @path)
        with_database do |db|
          schema = [
            'PRAGMA journal_mode = WAL;',
            'PRAGMA foreign_keys = ON;',
            'CREATE TABLE IF NOT EXISTS users (',
            'id INTEGER PRIMARY KEY,',
            'username TEXT NOT NULL COLLATE NOCASE UNIQUE,',
            'password_hash TEXT NOT NULL,',
            "role TEXT NOT NULL CHECK (role IN ('administrator', 'viewer')),",
            'enabled INTEGER NOT NULL DEFAULT 1,',
            'created_at INTEGER NOT NULL,',
            'updated_at INTEGER NOT NULL,',
            'last_login_at INTEGER);',
            'CREATE TABLE IF NOT EXISTS sessions (',
            'token_hash TEXT PRIMARY KEY,',
            'user_id INTEGER REFERENCES users(id) ON DELETE CASCADE,',
            'csrf_token TEXT NOT NULL,',
            'created_at INTEGER NOT NULL,',
            'last_seen_at INTEGER NOT NULL);',
            'CREATE INDEX IF NOT EXISTS sessions_user_id ON sessions(user_id);',
            'CREATE TABLE IF NOT EXISTS login_attempts (',
            'attempt_key TEXT PRIMARY KEY,',
            'failures INTEGER NOT NULL,',
            'window_started_at INTEGER NOT NULL,',
            'locked_until INTEGER);',
            'CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);',
            'CREATE TABLE IF NOT EXISTS audit_events (',
            'id INTEGER PRIMARY KEY,',
            'actor_id INTEGER,',
            'action TEXT NOT NULL,',
            'target TEXT NOT NULL,',
            'occurred_at INTEGER NOT NULL,',
            'FOREIGN KEY(actor_id) REFERENCES users(id) ON DELETE SET NULL);'
          ]
          db.execute_batch(schema.join(' '))
        end
        File.chmod(0o600, @path)
        with_database do |db|
          db.execute('INSERT OR IGNORE INTO metadata (key, value) VALUES (?, ?)', ['login_hmac_key', SecureRandom.hex(32)])
          @attempt_key = db.get_first_value('SELECT value FROM metadata WHERE key = ?', ['login_hmac_key'])
        end
        @dummy_password_hash = password_hash('not-a-real-password')
      rescue SQLite3::Exception, SystemCallError => e
        raise Error, "Unable to initialize the authentication database (#{e.class})."
      end

      def user_count
        with_database { |db| db.get_first_value('SELECT COUNT(*) FROM users').to_i }
      end

      def create_initial_admin(username, password)
        validate_credentials!(username, password)
        with_database do |db|
          db.transaction
          raise Error, 'An administrator already exists; use the administrator interface to add users.' if db.get_first_value("SELECT COUNT(*) FROM users WHERE role = 'administrator'").to_i.positive?

          now = Time.now.to_i
          db.execute(
            'INSERT INTO users (username, password_hash, role, enabled, created_at, updated_at) VALUES (?, ?, ?, 1, ?, ?)',
            [username.strip, password_hash(password), 'administrator', now, now]
          )
          id = db.last_insert_row_id
          db.commit
          id
        rescue SQLite3::ConstraintException
          db.rollback
          raise Error, 'That username is already in use.'
        rescue StandardError
          db.rollback
          raise
        end
      rescue SQLite3::Exception => e
        raise Error, "Unable to create the administrator (#{e.class})."
      end

      def create_user(username:, password:, role:)
        validate_credentials!(username, password)
        validate_role!(role)
        now = Time.now.to_i
        with_database do |db|
          db.execute(
            'INSERT INTO users (username, password_hash, role, enabled, created_at, updated_at) VALUES (?, ?, ?, 1, ?, ?)',
            [username.strip, password_hash(password), role.to_s, now, now]
          )
          user_by_id(db, db.last_insert_row_id)
        end
      rescue SQLite3::ConstraintException
        raise Error, 'That username is already in use.'
      rescue SQLite3::Exception => e
        raise Error, "Unable to create the user (#{e.class})."
      end

      def update_user(id, username: nil, role: nil, enabled: nil, password: nil)
        validate_role!(role) if role
        validate_username!(username) if username
        validate_password!(password) if password.to_s.length.positive?
        with_database do |db|
          db.transaction
          current = user_by_id(db, id)
          raise Error, 'User was not found.' unless current

          new_role = (role || current[:role]).to_s
          new_enabled = enabled.nil? ? current[:enabled] : enabled
          ensure_an_administrator_remains!(db, id, new_role, new_enabled)
          fields = { username: username&.strip, role: new_role, enabled: new_enabled ? 1 : 0, updated_at: Time.now.to_i }.compact
          fields[:password_hash] = password_hash(password) if password.to_s.length.positive?
          assignments = fields.keys.map { |key| "#{key} = ?" }.join(', ')
          db.execute("UPDATE users SET #{assignments} WHERE id = ?", fields.values + [id.to_i])
          db.execute('DELETE FROM sessions WHERE user_id = ?', [id.to_i]) if fields.has_key?(:password_hash) || !new_enabled
          updated = user_by_id(db, id)
          db.commit
          updated
        rescue SQLite3::ConstraintException
          db.rollback
          raise Error, 'That username is already in use.'
        rescue StandardError
          db.rollback
          raise
        end
      rescue SQLite3::Exception => e
        raise Error, "Unable to update the user (#{e.class})."
      end

      def delete_user(id)
        with_database do |db|
          db.transaction
          user = user_by_id(db, id)
          raise Error, 'User was not found.' unless user

          ensure_an_administrator_remains!(db, id, 'deleted', false) if user[:role] == 'administrator'

          db.execute('DELETE FROM users WHERE id = ?', [id.to_i])
          db.commit
          user
        rescue StandardError
          db.rollback
          raise
        end
      rescue SQLite3::Exception => e
        raise Error, "Unable to delete the user (#{e.class})."
      end

      def users
        with_database do |db|
          db.execute('SELECT id, username, role, enabled, created_at, updated_at, last_login_at FROM users ORDER BY username COLLATE NOCASE').map do |row|
            symbolize_user(row)
          end
        end
      end

      def authenticate(username, password)
        normalized = username.to_s.strip
        return nil if normalized.bytesize > 256 || password.to_s.bytesize > 1024

        with_database do |db|
          row = db.get_first_row('SELECT * FROM users WHERE username = ? COLLATE NOCASE', [normalized])
          valid = verify_password(password.to_s, (row && row['password_hash']) || @dummy_password_hash)
          next nil unless row && row['enabled'].to_i == 1 && valid

          db.execute('UPDATE users SET last_login_at = ? WHERE id = ?', [Time.now.to_i, row['id']])
          symbolize_user(row.merge('last_login_at' => Time.now.to_i))
        end
      end

      def create_session(user_id = nil)
        token = SecureRandom.urlsafe_base64(48)
        csrf_token = SecureRandom.urlsafe_base64(32)
        now = Time.now.to_i
        with_database do |db|
          db.execute('DELETE FROM sessions WHERE created_at < ?', [now - SESSION_ABSOLUTE_SECONDS])
          db.execute(
            'INSERT INTO sessions (token_hash, user_id, csrf_token, created_at, last_seen_at) VALUES (?, ?, ?, ?, ?)',
            [Digest::SHA256.hexdigest(token), user_id, csrf_token, now, now]
          )
        end
        { id: token, csrf_token: csrf_token }
      end

      def find_session(token)
        return nil if token.to_s.empty?

        now = Time.now.to_i
        with_database do |db|
          row = db.get_first_row(
            'SELECT s.*, u.id AS account_id, u.username, u.role, u.enabled FROM sessions s LEFT JOIN users u ON u.id = s.user_id WHERE s.token_hash = ?',
            [Digest::SHA256.hexdigest(token)]
          )
          next nil unless row

          if now - row['created_at'].to_i > SESSION_ABSOLUTE_SECONDS || now - row['last_seen_at'].to_i > SESSION_IDLE_SECONDS || (row['user_id'] && row['enabled'].to_i != 1)
            db.execute('DELETE FROM sessions WHERE token_hash = ?', [Digest::SHA256.hexdigest(token)])
            next nil
          end

          db.execute('UPDATE sessions SET last_seen_at = ? WHERE token_hash = ?', [now, Digest::SHA256.hexdigest(token)]) if now - row['last_seen_at'].to_i >= 60
          { csrf_token: row['csrf_token'], user: row['account_id'] && { id: row['account_id'], username: row['username'], role: row['role'].to_sym } }
        end
      end

      def invalidate_session(token)
        return if token.to_s.empty?

        with_database { |db| db.execute('DELETE FROM sessions WHERE token_hash = ?', [Digest::SHA256.hexdigest(token)]) }
      end

      def login_locked?(keys)
        now = Time.now.to_i
        with_database do |db|
          keys.any? do |key|
            row = db.get_first_row('SELECT locked_until FROM login_attempts WHERE attempt_key = ?', [attempt_hash(key)])
            row && row['locked_until'].to_i > now
          end
        end
      end

      def record_login_failure(keys)
        now = Time.now.to_i
        with_database do |db|
          db.transaction
          db.execute('DELETE FROM login_attempts WHERE window_started_at < ?', [now - LOGIN_WINDOW_SECONDS])
          keys.each do |key|
            hashed = attempt_hash(key)
            row = db.get_first_row('SELECT failures, window_started_at FROM login_attempts WHERE attempt_key = ?', [hashed])
            failures = row && now - row['window_started_at'].to_i < LOGIN_WINDOW_SECONDS ? row['failures'].to_i + 1 : 1
            started = row && now - row['window_started_at'].to_i < LOGIN_WINDOW_SECONDS ? row['window_started_at'].to_i : now
            locked_until = failures >= LOGIN_MAX_FAILURES ? now + LOGIN_WINDOW_SECONDS : nil
            db.execute(
              'INSERT INTO login_attempts (attempt_key, failures, window_started_at, locked_until) VALUES (?, ?, ?, ?) ON CONFLICT(attempt_key) DO UPDATE SET failures = excluded.failures, window_started_at = excluded.window_started_at, locked_until = excluded.locked_until',
              [hashed, failures, started, locked_until]
            )
          end
          db.commit
        rescue StandardError
          db.rollback
          raise
        end
      end

      def clear_login_failures(keys)
        with_database do |db|
          keys.each { |key| db.execute('DELETE FROM login_attempts WHERE attempt_key = ?', [attempt_hash(key)]) }
        end
      end

      def record_audit(actor_id, action, target)
        with_database do |db|
          db.execute('INSERT INTO audit_events (actor_id, action, target, occurred_at) VALUES (?, ?, ?, ?)',
                     [actor_id, action.to_s, target.to_s, Time.now.to_i])
        end
      end

      private

      def with_database
        db = SQLite3::Database.new(@path)
        db.results_as_hash = true
        db.busy_timeout = 5_000
        db.execute('PRAGMA foreign_keys = ON')
        yield db
      ensure
        db&.close
      end

      def password_hash(password)
        salt = SecureRandom.random_bytes(16)
        digest = OpenSSL::KDF.pbkdf2_hmac(password, salt: salt, iterations: ITERATIONS, length: 32, hash: 'sha256')
        "pbkdf2-sha256$#{ITERATIONS}$#{Base64.strict_encode64(salt)}$#{Base64.strict_encode64(digest)}"
      end

      def verify_password(password, encoded)
        algorithm, iterations, salt, expected = encoded.split('$', 4)
        return false unless algorithm == 'pbkdf2-sha256' && iterations.to_i.between?(100_000, 2_000_000)

        actual = OpenSSL::KDF.pbkdf2_hmac(password, salt: Base64.strict_decode64(salt), iterations: iterations.to_i, length: 32, hash: 'sha256')
        OpenSSL.fixed_length_secure_compare(actual, Base64.strict_decode64(expected))
      rescue ArgumentError, OpenSSL::OpenSSLError
        false
      end

      def validate_credentials!(username, password)
        validate_username!(username)
        validate_password!(password)
      end

      def validate_username!(username)
        value = username.to_s.strip
        raise Error, 'Username must be 3 to 64 characters and use letters, numbers, dot, underscore, or hyphen.' unless value.match?(/\A[a-zA-Z0-9._-]{3,64}\z/)
      end

      def validate_password!(password)
        raise Error, 'Password must contain at least 12 characters.' if password.to_s.length < 12
        raise Error, 'Password must be no more than 1024 bytes.' if password.to_s.bytesize > 1024
      end

      def validate_role!(role)
        raise Error, 'Role must be administrator or viewer.' unless %w[administrator viewer].include?(role.to_s)
      end

      def ensure_an_administrator_remains!(db, id, new_role, new_enabled)
        return unless new_role != 'administrator' || !new_enabled

        other_admins = db.get_first_value("SELECT COUNT(*) FROM users WHERE role = 'administrator' AND enabled = 1 AND id != ?", [id.to_i]).to_i
        raise Error, 'At least one enabled administrator account must remain.' if other_admins.zero?
      end

      def user_by_id(db, id)
        row = db.get_first_row('SELECT id, username, role, enabled, created_at, updated_at, last_login_at FROM users WHERE id = ?', [id.to_i])
        row && symbolize_user(row)
      end

      def symbolize_user(row)
        {
          id: row['id'].to_i,
          username: row['username'],
          role: row['role'].to_sym,
          enabled: row['enabled'].to_i == 1,
          created_at: row['created_at'] && Time.at(row['created_at'].to_i),
          updated_at: row['updated_at'] && Time.at(row['updated_at'].to_i),
          last_login_at: row['last_login_at'] && Time.at(row['last_login_at'].to_i)
        }
      end

      def attempt_hash(value)
        OpenSSL::HMAC.hexdigest('SHA256', @attempt_key, value.to_s)
      end
    end
  end
end
