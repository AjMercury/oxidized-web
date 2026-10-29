# Needed to get the error output on the console and not in last_response.body
ENV['APP_ENV'] = 'test'

require 'simplecov'
SimpleCov.start

require 'minitest/autorun'
require 'rack/test'
require 'tmpdir'
require 'oxidized'
require 'oxidized/web'
require 'oxidized/web/webapp'
require 'oxidized/web/user_store'
require 'mocha/minitest'

module AuthenticatedWebTestGateway
  class << self
    def prepare(role = :administrator)
      unless @store
        @directory = Dir.mktmpdir('oxidized-web-suite-auth')
        @store = Oxidized::API::UserStore.new(File.join(@directory, 'auth.sqlite3'))
        @admin_id = @store.create_initial_admin('test-admin', 'test-admin-password-123')
        @viewer = @store.create_user(username: 'test-viewer', password: 'test-viewer-password-123', role: 'viewer')
        at_exit { FileUtils.remove_entry(@directory) if File.directory?(@directory) }
      end
      user_id = role == :administrator ? @admin_id : @viewer[:id]
      session = @store.create_session(user_id)
      @token = session[:id]
      @csrf = session[:csrf_token]
      Oxidized::API::WebApp.set(:auth_store, @store)
      Oxidized::API::WebApp.set(:auth_require_https, false)
      Oxidized::API::WebApp.set(:trusted_proxies, ['127.0.0.1', '::1'])
    end

    def clear
      @token = nil
      @csrf = nil
    end

    def as_role(role)
      prepare(role)
    end

    def set(*args)
      Oxidized::API::WebApp.set(*args)
    end

    def call(env)
      if @token
        cookies = env['HTTP_COOKIE'].to_s.split(';').map(&:strip).reject { |cookie| cookie.start_with?('oxidized_web_session=') }
        cookies << "oxidized_web_session=#{@token}"
        env['HTTP_COOKIE'] = cookies.join('; ')
        env['HTTP_X_CSRF_TOKEN'] = @csrf if %w[GET HEAD OPTIONS].none? { |method| method == env['REQUEST_METHOD'] } && !env.has_key?('HTTP_X_CSRF_TOKEN')
        env['HTTP_ORIGIN'] ||= 'https://example.org' unless %w[GET HEAD OPTIONS].include?(env['REQUEST_METHOD'])
      end
      env['HTTP_HOST'] ||= 'example.org'
      env['REMOTE_ADDR'] ||= '127.0.0.1'
      env['rack.url_scheme'] ||= 'http'
      Oxidized::API::WebApp.call(env)
    end
  end
end
