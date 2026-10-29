require_relative '../spec_helper'
require 'tmpdir'

describe Oxidized::API::UserStore do
  before do
    @directory = Dir.mktmpdir('oxidized-web-user-store')
    @path = File.join(@directory, 'users.sqlite3')
    @store = Oxidized::API::UserStore.new(@path)
    @admin_id = @store.create_initial_admin('root-admin', 'long-admin-password-123')
  end

  after do
    FileUtils.remove_entry(@directory) if File.directory?(@directory)
  end

  it 'stores password hashes, verifies passwords, and rejects weak credentials' do
    db = SQLite3::Database.new(@path)
    password_hash = db.get_first_value('SELECT password_hash FROM users WHERE id = ?', [@admin_id])
    db.close

    _(password_hash).must_match(/\Apbkdf2-sha256\$600000\$/)
    _(password_hash).wont_include('long-admin-password-123')
    _(@store.authenticate('root-admin', 'long-admin-password-123')[:role]).must_equal :administrator
    _(@store.authenticate('root-admin', 'wrong-password')).must_be_nil
    _ { @store.create_user(username: 'short', password: 'short', role: 'viewer') }
      .must_raise(Oxidized::API::UserStore::Error)
  end

  it 'restricts the authentication database file to its owner on POSIX systems' do
    skip 'POSIX file mode is not available on Windows' if Gem.win_platform?

    _(File.file?(@path)).must_equal true
    _(File.stat(@path).mode & 0o777).must_equal 0o600
  end

  it 'creates missing authentication database directories with private permissions' do
    skip 'POSIX directory mode is not available on Windows' if Gem.win_platform?

    nested_path = File.join(@directory, 'private', 'nested', 'users.sqlite3')
    Oxidized::API::UserStore.new(nested_path)

    _(File.stat(File.dirname(nested_path)).mode & 0o777).must_equal 0o700
    _(File.stat(File.dirname(File.dirname(nested_path))).mode & 0o777).must_equal 0o700
  end

  it 'creates, updates, disables, and deletes users while preserving a usable administrator' do
    viewer = @store.create_user(username: 'readonly', password: 'long-viewer-password-123', role: 'viewer')
    _(viewer[:role]).must_equal :viewer
    updated = @store.update_user(viewer[:id], username: 'observer', role: 'administrator')
    _(updated[:username]).must_equal 'observer'
    _(updated[:role]).must_equal :administrator

    @store.update_user(viewer[:id], role: 'viewer')
    disabled = @store.update_user(viewer[:id], enabled: false)
    _(disabled[:enabled]).must_equal false
    _(@store.authenticate('observer', 'long-viewer-password-123')).must_be_nil
    _ { @store.update_user(@admin_id, enabled: false) }.must_raise(Oxidized::API::UserStore::Error)

    removed = @store.delete_user(viewer[:id])
    _(removed[:username]).must_equal 'observer'
    _(@store.users.inject([]) { |ids, user| ids << user[:id] }).must_equal [@admin_id]
  end

  it 'invalidates a user session after a password reset and expires idle sessions' do
    session = @store.create_session(@admin_id)
    _(@store.find_session(session[:id])[:user][:username]).must_equal 'root-admin'
    @store.update_user(@admin_id, password: 'new-admin-password-456')
    _(@store.find_session(session[:id])).must_be_nil
    _(@store.authenticate('root-admin', 'new-admin-password-456')[:id]).must_equal @admin_id

    expiring = @store.create_session(@admin_id)
    db = SQLite3::Database.new(@path)
    db.execute('UPDATE sessions SET last_seen_at = ? WHERE token_hash = ?',
               [Time.now.to_i - Oxidized::API::UserStore::SESSION_IDLE_SECONDS - 1, Digest::SHA256.hexdigest(expiring[:id])])
    db.close
    _(@store.find_session(expiring[:id])).must_be_nil
  end

  it 'expires a recently active session after its absolute lifetime' do
    session = @store.create_session(@admin_id)
    db = SQLite3::Database.new(@path)
    db.execute('UPDATE sessions SET created_at = ?, last_seen_at = ? WHERE token_hash = ?',
               [Time.now.to_i - Oxidized::API::UserStore::SESSION_ABSOLUTE_SECONDS - 1, Time.now.to_i,
                Digest::SHA256.hexdigest(session[:id])])
    db.close

    _(@store.find_session(session[:id])).must_be_nil
  end

  it 'stores auditable actions without recording password values' do
    @store.record_audit(@admin_id, 'login', 'root-admin')
    db = SQLite3::Database.new(@path)
    db.results_as_hash = true
    event = db.get_first_row('SELECT action, target FROM audit_events WHERE actor_id = ?', [@admin_id])
    db.close

    _(event).must_equal({ 'action' => 'login', 'target' => 'root-admin' })
    _(event.values.join).wont_include('long-admin-password-123')
  end

  it 'persists brute-force lockouts across store instances without storing submitted usernames' do
    keys = ['ip:192.0.2.20', 'user:192.0.2.20:root-admin']
    Oxidized::API::UserStore::LOGIN_MAX_FAILURES.times { @store.record_login_failure(keys) }
    reopened = Oxidized::API::UserStore.new(@path)
    _(reopened.login_locked?(keys)).must_equal true
    db = SQLite3::Database.new(@path)
    attempt_keys = db.execute('SELECT attempt_key FROM login_attempts').flatten
    db.close
    _(attempt_keys.join).wont_include('root-admin')
  end
end
