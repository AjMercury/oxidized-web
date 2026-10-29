require_relative '../spec_helper'
require 'tmpdir'

describe 'Web authentication' do
  include Rack::Test::Methods

  def app
    Oxidized::API::WebApp
  end

  before do
    @directory = Dir.mktmpdir('oxidized-web-auth')
    @auth_store = Oxidized::API::UserStore.new(File.join(@directory, 'auth.sqlite3'))
    app.set(:auth_store, @auth_store)
    app.set(:auth_require_https, false)
    app.set(:trusted_proxies, ['127.0.0.1', '::1'])
    @nodes = mock('Oxidized::Nodes')
    app.set(:nodes, @nodes)
    app.set(:configuration, { hide_node_vars: [] })
    @admin_id = @auth_store.create_initial_admin('admin', 'correct horse battery staple')
  end

  after do
    FileUtils.remove_entry(@directory) if File.directory?(@directory)
  end

  it 'redirects dashboard pages and returns 401 for sensitive APIs before login' do
    ['/', '/nodes', '/nodes/stats', '/admin/devices', '/node/version?node_full=router1'].each do |path|
      get path
      _(last_response.status).must_equal 302, "#{path} was not redirected to login"
      _(last_response.location).must_include('/login')
    end

    ['/nodes.json', '/node/fetch/router1', '/node/version/view.json?node=router1&oid=deadbeef',
     '/node/version/view?node=router1&oid=deadbeef&format=text'].each do |path|
      get path
      _(last_response.status).must_equal 401, "#{path} exposed a sensitive API"
    end
    _(last_response.headers['Content-Type']).must_include('application/json')

    get '/css/oxidized.css'
    _(last_response.ok?).must_equal true

    get '/node/version/diffs?node=router1&oid=deadbeef'
    _(last_response.status).must_equal 302
  end

  it 'authenticates a user with a rotated server-side session and logs out' do
    get '/login'
    _(last_response.ok?).must_equal true
    _(last_response.headers['Cache-Control']).must_equal 'no-store'
    csrf = last_response.body[/name="csrf_token"[^>]*value="([^"]+)"/, 1]
    _(csrf).wont_be_nil(last_response.body)
    guest_id = last_response.headers['Set-Cookie'].to_s[/oxidized_web_session=([^;]+)/, 1]
    _(guest_id).wont_be_nil

    post '/login', { username: 'admin', password: 'correct horse battery staple', csrf_token: csrf },
         'HTTP_ORIGIN' => 'https://example.org', 'return_to' => '//attacker.example/'
    _(last_response.status).must_equal 302
    _(last_response.location).must_include('/nodes')
    _(last_response.headers['Set-Cookie'].to_s).must_include('oxidized_web_session=', last_response.headers.inspect)
    authenticated_id = last_response.headers['Set-Cookie'].to_s[/oxidized_web_session=([^;]+)/, 1]
    _(authenticated_id).wont_equal guest_id
    _(@auth_store.find_session(guest_id)).must_be_nil
    _(last_response.headers['Set-Cookie'].to_s.downcase).must_include('httponly')
    _(last_response.headers['Set-Cookie'].to_s.downcase).must_include('samesite=lax')
    db = SQLite3::Database.new(@auth_store.path)
    login_audits = db.get_first_value('SELECT COUNT(*) FROM audit_events WHERE action = ?', ['login']).to_i
    db.close
    _(login_audits).must_equal 1

    app.set(:nodes, Struct.new(:list).new([]))
    get '/nodes'
    _(last_response.ok?).must_equal true
    _(last_response.body).must_include('admin')

    csrf = last_response.body[/content="([^"]+)" name="csrf-token"/, 1]
    post '/logout', { csrf_token: csrf }, 'HTTP_ORIGIN' => 'https://example.org'
    _(last_response.status).must_equal 302
    db = SQLite3::Database.new(@auth_store.path)
    logout_audits = db.get_first_value('SELECT COUNT(*) FROM audit_events WHERE action = ?', ['logout']).to_i
    db.close
    _(logout_audits).must_equal 1
    get '/nodes'
    _(last_response.status).must_equal 302
  end

  it 'rejects invalid credentials and does not accept Basic authentication' do
    get '/login'
    csrf = last_response.body[/name="csrf_token"[^>]*value="([^"]+)"/, 1]
    post '/login', { username: 'admin', password: 'wrong', csrf_token: csrf }, 'HTTP_ORIGIN' => 'https://example.org'
    _(last_response.status).must_equal 401, last_response.body

    basic = { 'HTTP_AUTHORIZATION' => "Basic #{Base64.strict_encode64('admin:correct horse battery staple')}" }
    get '/nodes.json', {}, basic
    _(last_response.status).must_equal 401
  end

  it 'rate limits repeated invalid sign-ins by client address' do
    get '/login'
    csrf = last_response.body[/name="csrf_token"[^>]*value="([^"]+)"/, 1]
    Oxidized::API::UserStore::LOGIN_MAX_FAILURES.times do
      post '/login', { username: 'admin', password: 'wrong password', csrf_token: csrf },
           'HTTP_ORIGIN' => 'https://example.org'
      _(last_response.status).must_equal 401
    end
    post '/login', { username: 'admin', password: 'wrong password', csrf_token: csrf },
         'HTTP_ORIGIN' => 'https://example.org'
    _(last_response.status).must_equal 429
    _(last_response.body).must_include('Too many failed sign-in attempts')
  end

  it 'separates login-failure buckets by client behind a trusted reverse proxy' do
    get '/login'
    csrf = last_response.body[/name="csrf_token"[^>]*value="([^"]+)"/, 1]
    headers = { 'HTTP_ORIGIN' => 'https://example.org', 'REMOTE_ADDR' => '127.0.0.1' }

    Oxidized::API::UserStore::LOGIN_MAX_FAILURES.times do
      post '/login', { username: 'admin', password: 'wrong password', csrf_token: csrf },
           headers.merge('HTTP_X_FORWARDED_FOR' => '198.51.100.10')
      _(last_response.status).must_equal 401
    end

    post '/login', { username: 'admin', password: 'wrong password', csrf_token: csrf },
         headers.merge('HTTP_X_FORWARDED_FOR' => '198.51.100.11')
    _(last_response.status).must_equal 401
    post '/login', { username: 'admin', password: 'wrong password', csrf_token: csrf },
         headers.merge('HTTP_X_FORWARDED_FOR' => '198.51.100.10')
    _(last_response.status).must_equal 429
  end

  it 'ignores forwarding headers when the immediate peer is not trusted' do
    get '/login'
    csrf = last_response.body[/name="csrf_token"[^>]*value="([^"]+)"/, 1]
    headers = { 'HTTP_ORIGIN' => 'https://example.org', 'REMOTE_ADDR' => '203.0.113.20' }
    Oxidized::API::UserStore::LOGIN_MAX_FAILURES.times do |index|
      post '/login', { username: 'admin', password: 'wrong password', csrf_token: csrf },
           headers.merge('HTTP_X_FORWARDED_FOR' => "198.51.100.#{index}")
      _(last_response.status).must_equal 401
    end
    post '/login', { username: 'admin', password: 'wrong password', csrf_token: csrf },
         headers.merge('HTTP_X_FORWARDED_FOR' => '198.51.100.99')
    _(last_response.status).must_equal 429
  end

  it 'does not let a malformed proxy chain block sign-ins for other usernames' do
    get '/login'
    csrf = last_response.body[/name="csrf_token"[^>]*value="([^"]+)"/, 1]
    headers = { 'HTTP_ORIGIN' => 'https://example.org', 'REMOTE_ADDR' => '127.0.0.1',
                'HTTP_X_FORWARDED_FOR' => 'not-an-ip' }

    Oxidized::API::UserStore::LOGIN_MAX_FAILURES.times do
      post '/login', { username: 'admin', password: 'wrong password', csrf_token: csrf }, headers
      _(last_response.status).must_equal 401
    end

    post '/login', { username: 'viewer', password: 'wrong password', csrf_token: csrf }, headers
    _(last_response.status).must_equal 401
  end

  it 'requires CSRF tokens for authenticated state changes' do
    token = @auth_store.create_session(@admin_id)
    get '/admin/users', {}, 'HTTP_COOKIE' => "oxidized_web_session=#{token[:id]}"
    _(last_response.status).must_equal 200

    post '/logout', {}, 'HTTP_COOKIE' => "oxidized_web_session=#{token[:id]}"
    _(last_response.status).must_equal 403
  end

  it 'allows viewers to read inventory but blocks user administration' do
    viewer = @auth_store.create_user(username: 'readonly', password: 'viewer-password-long-123', role: 'viewer')
    viewer_session = @auth_store.create_session(viewer[:id])
    @nodes.stubs(:list).returns([])
    get '/nodes', {}, 'HTTP_COOKIE' => "oxidized_web_session=#{viewer_session[:id]}"
    _(last_response.ok?).must_equal true

    get '/admin/users', {}, 'HTTP_COOKIE' => "oxidized_web_session=#{viewer_session[:id]}"
    _(last_response.status).must_equal 403
  end

  it 'lets administrators manage users without returning submitted passwords' do
    session = @auth_store.create_session(@admin_id)
    headers = { 'HTTP_COOKIE' => "oxidized_web_session=#{session[:id]}",
                'HTTP_X_CSRF_TOKEN' => session[:csrf_token], 'HTTP_ORIGIN' => 'https://example.org' }
    post '/admin/users', { username: 'operator', password: 'another-long-password-123', role: 'viewer' }, headers
    _(last_response.status).must_equal 302
    _(last_response.location).must_include('/admin/users')
    _(last_response.body).wont_include('another-long-password-123')
  end

  it 'supports administrator user edit, password reset, session revocation, and deletion' do
    session = @auth_store.create_session(@admin_id)
    headers = { 'HTTP_COOKIE' => "oxidized_web_session=#{session[:id]}",
                'HTTP_X_CSRF_TOKEN' => session[:csrf_token], 'HTTP_ORIGIN' => 'https://example.org' }
    post '/admin/users', { username: 'operator', password: 'another-long-password-123', role: 'viewer' }, headers
    _(last_response.status).must_equal 302
    operator = @auth_store.users.find { |user| user[:username] == 'operator' }
    operator_session = @auth_store.create_session(operator[:id])

    post "/admin/users/#{operator[:id]}", { username: 'observer', role: 'viewer', enabled: '1',
                                            password: 'reset-password-long-456' }, headers
    _(last_response.status).must_equal 302
    _(@auth_store.authenticate('observer', 'reset-password-long-456')[:id]).must_equal operator[:id]
    _(@auth_store.find_session(operator_session[:id])).must_be_nil

    post "/admin/users/#{operator[:id]}/delete", {}, headers
    _(last_response.status).must_equal 302
    _(@auth_store.users.any? { |user| user[:id] == operator[:id] }).must_equal false
    db = SQLite3::Database.new(@auth_store.path)
    actions = db.execute('SELECT action FROM audit_events WHERE target = ? ORDER BY action', ['observer']).flatten
    db.close
    _(actions).must_equal %w[delete_user update_user]
  end

  it 'prevents an administrator from deleting their own active account' do
    session = @auth_store.create_session(@admin_id)
    headers = { 'HTTP_COOKIE' => "oxidized_web_session=#{session[:id]}",
                'HTTP_X_CSRF_TOKEN' => session[:csrf_token], 'HTTP_ORIGIN' => 'https://example.org' }
    post "/admin/users/#{@admin_id}/delete", {}, headers
    _(last_response.status).must_equal 403
    _(@auth_store.users.find { |user| user[:id] == @admin_id }[:enabled]).must_equal true
  end

  it 'blocks viewer user mutations, CSRF-less admin mutations, and last-admin disablement' do
    viewer = @auth_store.create_user(username: 'readonly', password: 'viewer-password-long-123', role: 'viewer')
    viewer_session = @auth_store.create_session(viewer[:id])
    viewer_headers = { 'HTTP_COOKIE' => "oxidized_web_session=#{viewer_session[:id]}",
                       'HTTP_X_CSRF_TOKEN' => viewer_session[:csrf_token], 'HTTP_ORIGIN' => 'https://example.org' }
    post '/admin/users', { username: 'blocked', password: 'another-long-password-123', role: 'viewer' }, viewer_headers
    _(last_response.status).must_equal 403

    admin_session = @auth_store.create_session(@admin_id)
    admin_cookie = { 'HTTP_COOKIE' => "oxidized_web_session=#{admin_session[:id]}" }
    post '/admin/users', { username: 'blocked', password: 'another-long-password-123', role: 'viewer' }, admin_cookie
    _(last_response.status).must_equal 403

    admin_headers = { 'HTTP_COOKIE' => "oxidized_web_session=#{admin_session[:id]}",
                      'HTTP_X_CSRF_TOKEN' => admin_session[:csrf_token], 'HTTP_ORIGIN' => 'https://example.org' }
    post "/admin/users/#{@admin_id}", { username: 'admin', role: 'administrator', enabled: '0' }, admin_headers
    _(last_response.status).must_equal 422
    _(@auth_store.users.find { |user| user[:id] == @admin_id }[:enabled]).must_equal true
  end

  it 'requires HTTPS unless the TLS scheme comes from a trusted proxy' do
    app.set(:auth_require_https, true)
    app.set(:trusted_proxies, ['127.0.0.1'])
    get '/login', {}, 'HTTP_X_FORWARDED_PROTO' => 'https', 'REMOTE_ADDR' => '203.0.113.5'
    _(last_response.status).must_equal 403

    get '/login', {}, 'HTTP_X_FORWARDED_PROTO' => 'https', 'REMOTE_ADDR' => '127.0.0.1'
    _(last_response.ok?).must_equal true
    _(last_response.headers['Set-Cookie'].to_s.downcase).must_include('secure')
  end
end
