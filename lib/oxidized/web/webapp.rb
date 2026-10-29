require 'sinatra/base'
require 'sinatra/url_for'
require 'tilt/haml'
require 'htmlentities'
require 'charlock_holmes'
require 'openssl'
require 'ipaddr'
require 'securerandom'
require 'uri'
require 'time'
require 'oxidized/web/device_inventory'
require 'oxidized/web/user_store'
module Oxidized
  module API
    require 'oxidized/web/version'

    class WebApp < Sinatra::Base
      VERSION_CACHE_LOCK = Mutex.new
      VERSION_CACHE = {} # rubocop:disable Style/MutableConstant

      helpers Sinatra::UrlForHelper
      set :public_folder, proc { File.join(root, 'public') }
      set :static_cache_control, ['public', 'max-age=0', 'must-revalidate']
      # attr_quote: use double quotes for HTML attributes. Set explicitly so the
      # output is stable across Haml versions. Haml 7.3.0 changed the default
      # from "'" to '"' (haml/haml#1188); older versions still default to "'".
      set :haml, { escape_html: true, attr_quote: '"' }
      set :sessions, false

      before do
        response.headers['X-Content-Type-Options'] = 'nosniff'
        response.headers['X-Frame-Options'] = 'DENY'
        response.headers['Referrer-Policy'] = 'same-origin'
        response.headers['Content-Security-Policy'] = "default-src 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline'; object-src 'none'; base-uri 'self'; form-action 'self'; frame-ancestors 'none'"
        response.headers['Strict-Transport-Security'] = 'max-age=31536000' if settings.auth_require_https
        response.headers['Cache-Control'] = if request.path_info.match?(%r{\A/(?:css|scripts)/})
                                              'public, max-age=0, must-revalidate'
                                            else
                                              static_asset_path? ? 'public, max-age=3600' : 'no-store'
                                            end
        halt 503, 'Authentication is unavailable. Configure the Oxidized Web SQLite authentication database.' unless auth_store
        enforce_https!

        if public_auth_path?
          prepare_login_session! if request.path_info == '/login'
        else
          session = auth_store.find_session(request.cookies['oxidized_web_session'])
          @current_user = session && session[:user]
          @current_admin = @current_user && (@current_user[:role] == :administrator ? :admin : :viewer)
          @csrf_token = session && session[:csrf_token]
          unless @current_user
            auth_store.invalidate_session(request.cookies['oxidized_web_session']) if request.cookies['oxidized_web_session']
            clear_session_cookie
            if api_request?
              content_type :json
              halt 401, JSON.generate(error: 'authentication_required')
            end

            redirect url_for("/login?return_to=#{Rack::Utils.escape(request.fullpath)}")
            halt
          end

          unless %w[GET HEAD OPTIONS].include?(request.request_method)
            verify_csrf!
            verify_admin_origin!
          end
        end
      end

      error UserStore::Error do
        logger.error('Web authentication storage failed.')
        status 503
        'Authentication service is unavailable. Check the Oxidized Web authentication database.'
      end

      error SQLite3::Exception do
        logger.error('Web authentication database operation failed.')
        status 503
        'Authentication service is unavailable. Check the Oxidized Web authentication database.'
      end

      get '/' do
        redirect url_for('/nodes')
      end

      get '/login' do
        redirect url_for('/nodes') if @current_user
        @return_to = safe_return_path(params['return_to'])
        @remembered_username = request.cookies['oxidized_web_username'].to_s
        haml :login, layout: false
      end

      post '/login' do
        client_ip = client_ip_address
        attempted_username = params['username'].to_s.byteslice(0, 64).to_s.downcase
        # Do not create a proxy-wide lockout bucket: one client must not be
        # able to block every user behind a shared reverse proxy.
        keys = ["user:#{client_ip}:#{attempted_username}"]
        if auth_store.login_locked?(keys)
          status 429
          @login_error = 'Too many failed sign-in attempts. Wait 15 minutes and try again.'
          @return_to = safe_return_path(params['return_to'])
          haml :login, layout: false
        else
          user = auth_store.authenticate(params['username'], params['password'])
          unless user
            auth_store.record_login_failure(keys)
            status 401
            @login_error = 'Username or password is incorrect, or this account is disabled.'
            @return_to = safe_return_path(params['return_to'])
            halt haml(:login, layout: false)
          end

          auth_store.clear_login_failures(keys)
          auth_store.invalidate_session(request.cookies['oxidized_web_session'])
          issued = auth_store.create_session(user[:id])
          issue_session_cookie(issued[:id])
          set_cookie('oxidized_web_username', params['remember_username'] == '1' ? user[:username] : '',
                     httponly: true, max_age: params['remember_username'] == '1' ? 2_592_000 : 0)
          auth_store.record_audit(user[:id], 'login', user[:username])
          redirect url_for(safe_return_path(params['return_to']) || '/nodes')
        end
      end

      post '/logout' do
        auth_store.invalidate_session(request.cookies['oxidized_web_session'])
        auth_store.record_audit(@current_user[:id], 'logout', @current_user[:username])
        clear_session_cookie
        redirect url_for('/login')
      end

      get '/profile' do
        haml :profile, layout: true
      end

      post '/profile/password' do
        password = params['new_password'].to_s
        halt 422, 'The new password confirmation does not match.' unless params['new_password_confirmation'].to_s == password
        halt 403, 'Current password is incorrect.' unless auth_store.authenticate(@current_user[:username], params['current_password'])

        auth_store.update_user(@current_user[:id], password: password)
        issued = auth_store.create_session(@current_user[:id])
        issue_session_cookie(issued[:id])
        auth_store.record_audit(@current_user[:id], 'change_password', @current_user[:username])
        redirect url_for('/profile?password_changed=1')
      rescue UserStore::Error => e
        status 422
        @profile_error = e.message
        haml :profile, layout: true
      end

      get '/admin/users' do
        require_administrator!
        @users = auth_store.users
        haml :users, layout: true
      end

      get '/admin/users/new' do
        require_administrator!
        @user = { username: '', role: :viewer, enabled: true }
        haml :user_form, layout: true
      end

      post '/admin/users' do
        require_administrator!
        user = auth_store.create_user(username: params['username'], password: params['password'], role: params['role'])
        auth_store.record_audit(@current_user[:id], 'create_user', user[:username])
        redirect url_for('/admin/users')
      rescue UserStore::Error => e
        status 422
        @user = params
        @form_error = e.message
        haml :user_form, layout: true
      end

      get '/admin/users/:id/edit' do
        require_administrator!
        @user = auth_store.users.find { |user| user[:id] == params[:id].to_i }
        halt 404, 'User not found.' unless @user
        haml :user_form, layout: true
      end

      post '/admin/users/:id' do
        require_administrator!
        enabled = params['enabled'] == '1'
        user = auth_store.update_user(params[:id], username: params['username'], role: params['role'],
                                                   enabled: enabled, password: params['password'])
        auth_store.record_audit(@current_user[:id], 'update_user', user[:username])
        redirect url_for('/admin/users')
      rescue UserStore::Error => e
        status 422
        @user = params.merge('id' => params[:id])
        @form_error = e.message
        haml :user_form, layout: true
      end

      post '/admin/users/:id/delete' do
        require_administrator!
        halt 403, 'You cannot delete the account you are using.' if params[:id].to_i == @current_user[:id]

        user = auth_store.delete_user(params[:id])
        auth_store.record_audit(@current_user[:id], 'delete_user', user[:username])
        redirect url_for('/admin/users')
      rescue UserStore::Error => e
        halt 409, e.message
      end

      get '/favicon.ico' do
        redirect url_for('/images/favicon.ico')
      end

      # :filter can be "group" or "model"
      # URL: /nodes/group/<GroupName>[.json]
      # URL: /nodes/model/<ModelName>[.json]
      # an optional .json extension returns the data as JSON
      #
      # as GroupName can include /, we use splat to match its value
      # and extract the optional ".json" with route_parse
      get '/nodes/:filter/*' do
        value, @json = route_parse params[:splat].first
        @data = nodes.list.map { |node| filter_node_vars(node) }.select do |node|
          next unless node[params[:filter].to_sym] == value ||
                      (
                        params[:filter].to_sym == :group &&
                        node[params[:filter].to_sym].nil? &&
                        value.to_sym == :default
                      )

          node[:group] = 'default' unless node[:group]
          apply_backup_summary!(node)
          node
        end
        out :nodes
      end

      get '/nodes.?:format?' do
        @management_error = inventory_management_unavailable_reason
        @data = nodes.list.map do |node|
          node = filter_node_vars(node)
          node[:group] = 'default' unless node[:group]
          apply_backup_summary!(node)
          node
        end
        @dashboard_activity = dashboard_revision_activity(@data)
        out :nodes
      end

      post '/nodes/conf_search.?:format?' do
        search_term = params[:search_in_conf_textbox].to_s
        @nodes_match = []
        unless search_term.empty?
          begin
            @to_research = Regexp.new search_term
          rescue RegexpError
            @to_research = nil
          end
          if @to_research
            nodes.list.map.each do |n|
              node, @json = route_parse n[:name]
              config = nodes.fetch node, n[:group]
              @nodes_match.push({ node: n[:name], full_name: n[:full_name] }) if config[@to_research]
            end
          end
        end
        @data = @nodes_match
        out :conf_search
      end

      get '/nodes/stats.?:format?' do
        @data = {}
        nodes.each do |node|
          @data[node.name] = node.stats
        end
        out :stats
      end

      post '/reload.?:format?' do
        require_administrator!
        reload_inventory_safely!
        audit_admin!('reload_inventory', '-')
        @data = 'reloaded list of nodes'
        out
      end

      get '/admin/devices' do
        begin
          @inventory = DeviceInventory.new(nodes, Oxidized.config)
          @device_fields = @inventory.fields
          @group_assignable = @inventory.group_assignable?
        rescue DeviceInventory::Error => e
          @inventory_error = e.message
          @device_fields = []
        end
        @models = available_models
        @data = inventory_nodes
        haml :devices, layout: true
      end

      post '/admin/devices/bulk.?:format?' do
        require_administrator!
        names = Array(params['devices']).map(&:to_s).uniq
        raise DeviceInventory::Error, 'Select at least one device.' if names.empty?

        case params['operation']
        when 'export'
          require 'csv'
          selected = inventory_nodes.select { |node| names.include?(node[:name].to_s) }
          raise DeviceInventory::Error.new('One or more selected devices are no longer in the inventory.', status: 409) unless selected.length == names.length

          names.each { |name| audit_admin!('export', name) }
          content_type 'text/csv'
          headers['Content-Disposition'] = 'attachment; filename="oxidized-devices-selected.csv"'
          CSV.generate do |csv|
            csv << %w[name ip model group status last_backup]
            selected.each { |node| csv << [node[:name], node[:ip], node[:model], node[:group], node[:status], node[:time]] }
          end
        when 'backup'
          known_names = inventory_nodes.map { |node| node[:name].to_s }
          unknown = names - known_names
          raise DeviceInventory::Error.new('One or more selected devices are no longer in the inventory.', status: 409) unless unknown.empty?

          names.each do |name|
            nodes.next(name)
            audit_admin!('backup', name)
          end
          admin_mutation_response('queued backups for', names.join(', '))
        when 'group'
          inventory = DeviceInventory.new(nodes, Oxidized.config)
          inventory.assign_group(names, params['group']) { reload_inventory_safely! }
          names.each { |name| audit_admin!('assign_group', name) }
          admin_mutation_response('assigned group to', names.join(', '))
        when 'delete'
          inventory = DeviceInventory.new(nodes, Oxidized.config)
          inventory.delete_many(names) { reload_inventory_safely!(removed: names) }
          names.each { |name| audit_admin!('delete', name) }
          admin_mutation_response('deleted', names.join(', '))
        else
          raise DeviceInventory::Error, 'Select a supported bulk operation.'
        end
      rescue DeviceInventory::Error => e
        admin_error_response(e.message, e.status)
      rescue StandardError => e
        logger.error("Bulk device operation failed (#{e.class})")
        admin_error_response('Bulk operation failed. Check the Oxidized logs for details.', 500)
      end

      get '/admin/devices/export.csv' do
        require 'csv'
        content_type 'text/csv'
        headers['Content-Disposition'] = 'attachment; filename="oxidized-devices.csv"'
        CSV.generate do |csv|
          csv << %w[name ip model group status last_backup]
          inventory_nodes.each do |node|
            csv << [node[:name], node[:ip], node[:model], node[:group], node[:status], node[:time]]
          end
        end
      end

      get '/admin/devices/:name/edit' do
        require_administrator!
        @inventory = DeviceInventory.new(nodes, Oxidized.config)
        @device_fields = @inventory.fields
        @models = available_models
        @device = inventory_nodes.find { |node| node[:name] == params[:name] }
        halt 404, 'device not found' unless @device
        haml :device_edit, layout: true
      end

      post '/admin/devices.?:format?' do
        require_administrator!
        @inventory = DeviceInventory.new(nodes, Oxidized.config)
        attributes = device_attributes(params)
        validate_model!(attributes[:model])
        @inventory.create(attributes) { reload_inventory_safely!(expected: attributes[:name]) }
        audit_admin!('create', attributes[:name])
        admin_mutation_response('created', attributes[:name], 201)
      rescue DeviceInventory::Error => e
        admin_error_response(e.message, e.status)
      rescue StandardError => e
        logger.error("Device creation failed (#{e.class})")
        admin_error_response('Device could not be created. Check the Oxidized logs for details.', 500)
      end

      post '/admin/devices/:name.?:format?' do
        require_administrator!
        @inventory = DeviceInventory.new(nodes, Oxidized.config)
        attributes = device_attributes(params, include_name: false)
        attributes[:name] = params['new_name'] if params.has_key?('new_name')
        validate_model!(attributes[:model]) if attributes[:model]
        expected_name = attributes[:name] || params[:name]
        @inventory.update(params[:name], attributes) { reload_inventory_safely!(expected: expected_name) }
        audit_admin!('update', attributes[:name] || params[:name])
        admin_mutation_response('updated', attributes[:name] || params[:name])
      rescue DeviceInventory::Error => e
        admin_error_response(e.message, e.status)
      rescue StandardError => e
        logger.error("Device update failed (#{e.class})")
        admin_error_response('Device could not be updated. Check the Oxidized logs for details.', 500)
      end

      post '/admin/devices/:name/delete.?:format?' do
        require_administrator!
        inventory = DeviceInventory.new(nodes, Oxidized.config)
        inventory.delete(params[:name]) { reload_inventory_safely!(removed: params[:name]) }
        audit_admin!('delete', params[:name])
        admin_mutation_response('deleted', params[:name])
      rescue DeviceInventory::Error => e
        admin_error_response(e.message, e.status)
      rescue StandardError => e
        logger.error("Device deletion failed (#{e.class})")
        admin_error_response('Device could not be deleted. Check the Oxidized logs for details.', 500)
      end

      # URL: /node/fetch/<group>/<node>.json
      # Gets the configuration of a node
      # <group> is optional. If no group is given, nil will be passed to oxidized
      # .json is optional. If given, will return the output in json format
      get '/node/fetch/?*?/:node' do
        node, @json = route_parse :node
        group = params['splat'].first
        group = nil if group.empty?
        begin
          @data = nodes.fetch node, group
        rescue NodeNotFound => e
          @data = e.message
        end
        out :text
      end

      # URL: /node/fetch/<group>/<node>[.json]
      # <group> is optional, and not used
      # .json is optional. If given, will return 'ok'
      # if not, it redirects to /nodes
      post '/node/next/?*?/:node' do
        require_administrator!
        node, @json = route_parse :node
        nodes.next node
        audit_admin!('backup', node)
        redirect url_for('/nodes') unless @json
        @data = 'ok'
        out
      end

      # use this to attach author/email/message to commit
      put '/node/next/?*?/:node' do
        require_administrator!
        node, @json = route_parse :node
        opt = JSON.parse request.body.read
        nodes.next node, opt
        audit_admin!('backup', node)
        redirect url_for('/nodes') unless @json
        @data = 'ok'
        out
      end

      get '/node/show/*' do
        node_path, @json = route_parse params[:splat].first
        if node_path.include?('/')
          @data = nodes.list.find { |candidate| candidate[:full_name].to_s == node_path }
          halt 404, 'node not found' unless @data

          @data = filter_node_vars(@data)
          @device_full_name = @data[:full_name]
        else
          node_path = route_parse(:node).first if params[:node]
          @data = filter_node_vars(nodes.show(node_path))
          @device_full_name = @data[:full_name] || node_path
        end
        display_data = apply_backup_summary!(@data.dup)
        @device_status = display_data[:backup_state]
        @device_time = display_data[:last_attempt_at] || 'Not checked this session'
        @device_mtime = display_data[:last_changed_at] || 'Unknown'
        @device_revision_count = display_data[:revision_count]
        @management_error = inventory_management_unavailable_reason
        out :node
      end

      # display the versions of a node
      # URL: /node/version[.json]?node_full=<GroupName/NodeName>
      get '/node/version.?:format?' do
        @data = nil
        @group = nil
        @node = nil
        node_full = params[:node_full].to_s
        if node_full.include? '/'
          node_full = node_full.rpartition("/")
          @group = node_full[0]
          @node = node_full[2]
          @data = nodes.version @node, @group
        else
          @node = node_full
          @data = nodes.version @node, nil
        end
        out :versions
      end

      # show the blob of a version
      get '/node/version/view.?:format?' do
        node, @json = route_parse :node
        @info = {
          node: node,
          group: params[:group] || '',
          oid: params[:oid],
          time: Time.at(params[:epoch].to_i),
          num: params[:num]
        }

        the_data = nodes.get_version node, @info[:group].empty? ? nil : @info[:group], @info[:oid]
        if %w[json text].include?(params[:format])
          @data = the_data
        else
          utf8_encoded_content = convert_to_utf8(the_data)
          @data = HTMLEntities.new.encode(utf8_encoded_content)
        end
        out :version
      end

      # show diffs between 2 version
      get '/node/version/diffs' do
        node, @json = route_parse :node
        @data = nil
        @info = { node: node,
                  group: params[:group] || '',
                  oid: params[:oid],
                  time: Time.at(params[:epoch].to_i),
                  num: params[:num],
                  num2: (params[:num].to_i - 1) }
        group = nil
        group = @info[:group] if @info[:group] != ''
        @oids_dates = nodes.version node, group
        if params[:oid2]
          @info[:oid2] = params[:oid2]
          oid2 = nil
          num = @oids_dates.count + 1
          @oids_dates.each do |x|
            num -= 1
            next unless x[:oid].to_s == params[:oid2]

            oid2 = x[:oid]
            @info[:num2] = num
            break
          end
          @data = nodes.get_diff node, group, @info[:oid], oid2
        else
          @data = nodes.get_diff node, group, @info[:oid], nil
        end
        @stat = %w[null null]
        if @data != 'no diffs' && !@data.nil?
          @stat = @data[:stat]
          @data = @data[:patch]
        else
          @data = 'No diff available'
        end
        @diff_patch = @data
        @diff = diff_view @data
        out :diffs
      end

      # used for diff between 2 distant commit
      post '/node/version/diffs' do
        redirect url_for("/node/version/diffs?node=#{params[:node]}&group=#{params[:group]}&oid=#{params[:oid]}&epoch=#{params[:epoch]}&num=#{params[:num]}&oid2=#{params[:oid2]}")
      end

      # Taken von Haml 5.0, so it still works in 6.0
      HTML_ESCAPE = { '&' => '&amp;', '<' => '&lt;', '>' => '&gt;', '"' => '&quot;', "'" => '&#39;' }.freeze
      HTML_ESCAPE_ONCE_REGEX = /['"><]|&(?!(?:[a-zA-Z]+|#(?:\d+|[xX][0-9a-fA-F]+));)/

      private

      def out(template = :text)
        if @json || (params[:format] == 'json')
          content_type :json
          if @data.is_a?(String)
            JSON.generate(@data.lines)
          else
            JSON.generate(@data)
          end
        elsif (template == :text) || (params[:format] == 'text')
          content_type :text
          @data
        else
          haml template, layout: true
        end
      end

      def nodes
        settings.nodes
      end

      def auth_store
        settings.auth_store
      end

      def public_auth_path?
        %w[/login /favicon.ico].include?(request.path_info) || static_asset_path?
      end

      def static_asset_path?
        request.path_info.match?(%r{\A/(?:css|scripts|images|weblibs)/[a-zA-Z0-9_./-]+\z}) &&
          request.path_info.index('..').nil?
      end

      def api_request?
        request.path_info.start_with?('/node/fetch/') || request.path_info.end_with?('.json', '.csv') ||
          %w[json text].include?(params['format']) || request.accept.any? { |type| type.to_s == 'application/json' }
      end

      def enforce_https!
        return unless settings.auth_require_https
        return if request.env['rack.url_scheme'] == 'https' || request.env['HTTPS'] == 'on'
        return if trusted_proxy_request? && request.env['HTTP_X_FORWARDED_PROTO'].to_s.split(',').first.to_s.strip.casecmp('https').zero?

        halt 403, 'Oxidized Web requires HTTPS. Open the service through its configured HTTPS reverse proxy.'
      end

      def trusted_proxy_request?
        trusted_ip?(IPAddr.new(request.env['REMOTE_ADDR'].to_s))
      rescue IPAddr::InvalidAddressError
        false
      end

      def client_ip_address
        remote = IPAddr.new(request.env['REMOTE_ADDR'].to_s)
        return remote.to_s unless trusted_ip?(remote)

        forwarded = request.env['HTTP_X_FORWARDED_FOR'].to_s
        return remote.to_s if forwarded.empty?

        chain = forwarded.split(',').map { |address| IPAddr.new(address.strip) }
        return remote.to_s if chain.empty? || chain.length > 20

        chain << remote
        client = chain.pop
        while trusted_ip?(client)
          client = chain.pop
          return remote.to_s unless client
        end
        client.to_s
      rescue IPAddr::InvalidAddressError
        remote&.to_s || request.env['REMOTE_ADDR'].to_s
      end

      def trusted_ip?(address)
        Array(settings.trusted_proxies).any? { |proxy| IPAddr.new(proxy).include?(address) }
      end

      def prepare_login_session!
        token = request.cookies['oxidized_web_session']
        session = auth_store.find_session(token)
        @remembered_username = request.cookies['oxidized_web_username'].to_s
        if session.nil? && request.request_method == 'GET'
          issued = auth_store.create_session
          issue_session_cookie(issued[:id])
          session = { csrf_token: issued[:csrf_token], user: nil }
        end
        @csrf_token = session && session[:csrf_token]
        @current_user = session && session[:user]
        return unless request.request_method == 'POST'

        verify_csrf!(session)
        verify_admin_origin!
      end

      def verify_csrf!(session = nil)
        session ||= { csrf_token: @csrf_token }
        expected = session && session[:csrf_token].to_s
        provided = params['csrf_token'].to_s
        provided = request.env['HTTP_X_CSRF_TOKEN'].to_s if provided.empty?
        halt 403, 'The security token is missing or expired. Reload the page and try again.' if expected.empty? || provided.empty?
        halt 403, 'The security token is invalid. Reload the page and try again.' unless secure_compare(expected, provided)
      end

      def issue_session_cookie(token)
        response.set_cookie('oxidized_web_session', value: token, path: '/', httponly: true,
                                                    secure: settings.auth_require_https, same_site: :lax)
      end

      def clear_session_cookie
        response.set_cookie('oxidized_web_session', value: '', path: '/', httponly: true,
                                                    secure: settings.auth_require_https, same_site: :lax, max_age: 0)
      end

      def set_cookie(name, value, **options)
        response.set_cookie(name, { value: value, path: '/', secure: settings.auth_require_https,
                                    same_site: :lax }.merge(options))
      end

      def safe_return_path(value)
        path = value.to_s
        return nil unless path.start_with?('/') && !path.start_with?('//') && !path.match?(/[\r\n\\]/)

        path
      end

      def require_administrator!
        halt 403, 'Administrator role required.' unless @current_user && @current_user[:role] == :administrator
      end

      def audit_user!(action, target)
        auth_store.record_audit(@current_user[:id], action, target)
        logger.info("admin_audit action=#{action} user_id=#{@current_user[:id]} target=#{target.to_s.gsub(/[\r\n]/, '_')}")
      end

      def inventory_management_unavailable_reason
        return 'Administrator role is required for inventory changes.' unless @current_user && @current_user[:role] == :administrator

        DeviceInventory.new(nodes, Oxidized.config)
        supports_history_safe_reload? ? nil : 'Inventory writes require a Core version with history-preserving inventory reload support.'
      rescue DeviceInventory::Error => e
        e.message
      rescue StandardError => e
        logger.warn("Unable to check device management availability (#{e.class})")
        'Device management availability could not be verified. Check the Oxidized service configuration.'
      end

      def supports_history_safe_reload?
        nodes.method(:load).parameters.any? do |kind, name|
          (%i[key keyreq].include?(kind) && name == :clean_obsolete) || kind == :keyrest
        end
      end

      def secure_compare(left, right)
        return false unless left.bytesize == right.bytesize

        OpenSSL.fixed_length_secure_compare(left, right)
      end

      def verify_admin_origin!
        origin = request.env['HTTP_ORIGIN']
        referer = request.env['HTTP_REFERER']
        value = origin || referer
        halt 403, 'Administrative changes require a same-origin HTTPS request. Open Oxidized Web through its HTTPS reverse-proxy URL.' if value.to_s.empty?

        uri = URI.parse(value)
        halt 403, 'Administrative changes require a same-origin HTTPS request. Open Oxidized Web through its HTTPS reverse-proxy URL.' unless uri.scheme == 'https' && uri.host

        expected_host = request.env['HTTP_HOST'].to_s.downcase
        origin_host = uri.host.downcase
        origin_host += ":#{uri.port}" unless uri.port == uri.default_port
        halt 403, 'Administrative changes require a same-origin HTTPS request. Open Oxidized Web through its HTTPS reverse-proxy URL.' unless origin_host == expected_host
      rescue URI::InvalidURIError
        halt 403, 'Administrative changes require a same-origin HTTPS request. Open Oxidized Web through its HTTPS reverse-proxy URL.'
      end

      def reload_inventory_safely!(expected: nil, removed: nil)
        unless supports_history_safe_reload?
          raise DeviceInventory::Error.new(
            'This Oxidized Core version does not support history-preserving inventory reloads. Upgrade Core before changing inventory.',
            status: 409
          )
        end

        nodes.load(nil, clean_obsolete: false)
        current_names = nodes.list.map { |node| node[:name].to_s }
        if expected && current_names.index(expected.to_s).nil?
          raise DeviceInventory::Error.new(
            'Core reloaded the inventory but did not load the requested device. The CSV change was rolled back.',
            status: 422
          )
        end
        return unless removed

        removed_names = Array(removed).map(&:to_s)
        retained_names = removed_names & current_names
        return if retained_names.empty?

        raise DeviceInventory::Error.new('Core still reports removed devices after reload. The CSV change was rolled back.', status: 422)
      end

      def device_attributes(parameters, include_name: true)
        allowed = %w[ip model group username password enable description input ssh_port telnet_port timeout]
        allowed.unshift('name') if include_name
        allowed.each_with_object({}) do |key, result|
          result[key.to_sym] = parameters[key] if parameters.has_key?(key)
        end
      end

      def available_models
        models = %w[ios routeros]
        models.concat(Dir.glob(File.join(Oxidized::Config::MODEL_DIR, '*.rb')).map { |path| File.basename(path, '.rb') }) if defined?(Oxidized::Config::MODEL_DIR)
        models.uniq.sort
      end

      # Model names come from the active Core installation. Vendor labels are
      # hints for inventory browsing only; model availability remains the
      # source of truth for whether Core can retrieve a configuration.
      def vendor_for_model(model)
        value = model.to_s.downcase.gsub(/[^a-z0-9]/, '')
        return 'Cisco' if value.match?(/\A(?:ios|iosxe|iosxr|nxos|asa|cisco)/)
        return 'MikroTik' if value.include?('routeros') || value.include?('mikrotik')
        return 'Juniper' if value.include?('junos') || value.include?('juniper')
        return 'Arista' if value.include?('eos') || value.include?('arista')
        return 'Fortinet' if value.include?('forti')
        return 'Palo Alto Networks' if value.include?('panos') || value.include?('paloalto')
        return 'Huawei' if value.include?('vrp') || value.include?('huawei')
        return 'HPE' if value.include?('comware') || value.include?('hpe')
        return 'Aruba' if value.include?('aruba')
        return 'Dell' if value.include?('dellos') || value.include?('dell')
        return 'Ubiquiti' if value.match?(/ubnt|unifi|edgeos|ubiquiti/)

        'Other'
      end

      def vendor_logo(model)
        vendor_for_model(model).downcase.gsub(/[^a-z0-9]+/, '-')
      end

      def vendor_logo_asset(model)
        {
          'Cisco' => 'cisco',
          'MikroTik' => 'mikrotik',
          'Juniper' => 'junipernetworks',
          'Fortinet' => 'fortinet',
          'Palo Alto Networks' => 'paloaltonetworks',
          'Huawei' => 'huawei',
          'Ubiquiti' => 'ubiquiti',
          'Dell' => 'dell'
        }[vendor_for_model(model)]
      end

      def revision_count_for(node)
        backup_history_for(node)[:count]
      rescue StandardError => e
        logger.warn("Unable to read backup revision count for #{node[:name]} (#{e.class})")
        nil
      end

      def validate_model!(model)
        return if model.to_s.empty?
        return if available_models.include?(model.to_s)

        raise DeviceInventory::Error, 'Select an Oxidized model supported by this Core installation.'
      end

      def inventory_nodes
        nodes.list.map do |serialized_node|
          node = filter_node_vars(serialized_node)
          node[:group] ||= 'default'
          apply_backup_summary!(node)
          node
        end
      end

      # Core's last-run fields live in memory and reset when oxidized restarts.
      # Git history is the durable source for saved revisions and change time.
      # Keep the legacy status/time keys for API compatibility, while exposing
      # explicit fields that let clients distinguish session state from history.
      def apply_backup_summary!(node)
        history = backup_history_for(node)
        last = node[:last]
        node[:status] = last ? last[:status].to_s : 'never'
        node[:time] = last ? last[:end] : 'never'
        node[:last_attempt_status] = last ? last[:status].to_s : nil
        node[:last_attempt_at] = last && usable_timestamp(last[:end])
        node[:revision_count] = history[:count]
        node[:last_stored_revision_at] = history[:latest_at]
        node[:last_changed_at] = usable_timestamp(node[:mtime]) || history[:latest_at]
        node[:backup_state] = if last
                                last[:status].to_s
                              elsif history[:count].to_i.positive?
                                'not_checked_this_session'
                              else
                                'never_backed_up'
                              end
        node
      end

      def backup_history_for(node)
        @backup_history_cache ||= {}
        key = [node[:group].to_s, node[:name].to_s]
        return @backup_history_cache[key] if @backup_history_cache.has_key?(key)

        revisions = nodes.respond_to?(:version) ? nodes.version(node[:name], node[:group]) : nil
        revisions = [] unless revisions.is_a?(Array)
        latest = revisions.first
        latest_at = latest.is_a?(Hash) ? (latest[:time] || latest['time']) : nil
        latest_oid = latest.is_a?(Hash) ? (latest[:oid] || latest['oid']) : nil
        @backup_history_cache[key] = { count: revisions.length, latest_at: usable_timestamp(latest_at), latest_oid: latest_oid, revisions: revisions }
      rescue StandardError => e
        logger.warn("Unable to read backup history for #{node[:name]} (#{e.class})")
        @backup_history_cache[key] = { count: nil, latest_at: nil, latest_oid: nil, revisions: [] }
      end

      def dashboard_revision_activity(device_nodes)
        counts = Array.new(7, 0)
        today = Time.now.to_date
        device_nodes.each do |node|
          revisions = backup_history_for(node)[:revisions]
          next unless revisions.is_a?(Array)

          revisions.each do |revision|
            raw = revision.is_a?(Hash) ? (revision[:time] || revision['time']) : nil
            date = timestamp_time(raw)&.to_date if raw
            offset = (today - date).to_i if date
            counts[6 - offset] += 1 if offset&.between?(0, 6)
          end
        rescue StandardError => e
          logger.warn("Unable to read revision activity for #{node[:name]} (#{e.class})")
        end
        counts
      end

      def software_version_for(node)
        supplied = node.dig(:vars, 'version') || node.dig(:vars, :version) || node[:version]
        return supplied unless supplied.to_s.strip.empty? || supplied.to_s.casecmp('unknown').zero?

        history = backup_history_for(node)
        return 'Unknown' if history[:latest_oid].to_s.empty?

        key = [node[:group].to_s, node[:name].to_s, node[:model].to_s, history[:latest_oid].to_s]
        self.class::VERSION_CACHE_LOCK.synchronize do
          return self.class::VERSION_CACHE[key] if self.class::VERSION_CACHE.has_key?(key)
        end
        config = if nodes.respond_to?(:get_version)
                   nodes.get_version(node[:name], node[:group], history[:latest_oid])
                 else
                   nodes.fetch(node[:name], node[:group])
                 end
        version = parse_software_version(node[:model], config)
        self.class::VERSION_CACHE_LOCK.synchronize do
          self.class::VERSION_CACHE.shift while self.class::VERSION_CACHE.length >= 2048
          self.class::VERSION_CACHE[key] = version
        end
        version
      rescue StandardError => e
        logger.warn("Unable to detect software version for #{node[:name]} (#{e.class})")
        'Unknown'
      end

      def parse_software_version(model, config)
        text = config.to_s
        case model.to_s.downcase
        when /routeros|mikrotik/
          match = text.match(/^\s*#\s*[^\r\n]*?\bRouterOS\s+(\d+\.\d+(?:\.\d+)?(?:[a-zA-Z0-9.-]*))\b/i)
          "RouterOS #{match[1]}" if match
        when /ios\b|iosxe|ios_xe/
          match = text.match(/^\s*version\s+(\d+(?:\.\d+)+(?:[A-Za-z0-9.-]*))\s*$/i)
          "IOS #{match[1]}" if match
        when /nxos|nx_os/
          match = text.match(/^\s*!?\s*NX-OS(?:\s+version)?\s*[: ]\s*(\d+(?:\.\d+)+(?:[A-Za-z0-9.-]*))\s*$/i)
          "NX-OS #{match[1]}" if match
        when /junos|juniper/
          match = text.match(/^\s*#?\s*Junos:\s*(\d+(?:\.\d+[A-Za-z0-9.-]*)+)\s*$/i)
          "Junos #{match[1]}" if match
        end || 'Unknown'
      end

      def usable_timestamp(value)
        timestamp_time(value)
      end

      def timestamp_time(value)
        return value if value.is_a?(Time)

        text = value.to_s
        return Time.at(text.to_i) if text.match?(/\A\d+\z/)

        Time.parse(text)
      rescue ArgumentError, TypeError
        nil
      end

      def admin_mutation_response(action, name, status_code = nil)
        status status_code if status_code
        if params[:format] == 'json' || request.media_type == 'application/json'
          content_type :json
          JSON.generate(status: 'ok', action: action, device: name)
        else
          redirect url_for("/admin/devices?notice=#{action}")
        end
      end

      def admin_error_response(message, status_code)
        status status_code
        if params[:format] == 'json' || request.media_type == 'application/json'
          content_type :json
          JSON.generate(error: message)
        else
          content_type :text
          message
        end
      end

      def audit_admin!(action, name)
        device = name.to_s.gsub(/[\r\n]/, '_')
        audit_user!(action, device)
      end

      # checks if param ends with .json
      # if so, returns param without ".json" and true
      # if not, returns param and false
      def route_parse(param)
        json = false
        e = if param.respond_to?(:to_str)
              param.split '.'
            else
              params[param].to_s.split '.'
            end
        if e.last == 'json'
          e.pop
          json = true
        end
        [e.join('.'), json]
      end

      # give the time elapsed between now and a date (Time object)
      def time_from_now(date)
        return "no time specified" if date.nil?

        raise "time_from_now needs a Time object" unless date.instance_of? Time

        t = (Time.now - date).to_i
        mm, ss = t.divmod(60)
        hh, mm = mm.divmod(60)
        dd, hh = hh.divmod(24)
        if dd.positive?
          "#{dd} days #{hh} hours ago"
        elsif hh.positive?
          "#{hh} hours #{mm} min ago"
        else
          "#{mm} min #{ss} sec ago"
        end
      end

      # method the give diffs in separate view (the old and the new) as in github
      def diff_view(diff)
        old_diff = []
        new_diff = []

        utf8_encoded_content = convert_to_utf8(diff)
        HTMLEntities.new.encode(utf8_encoded_content).each_line do |line|
          if /^\+/.match(line)
            new_diff.push(line)
          elsif /^-/.match(line)
            old_diff.push(line)
          else
            new_diff.push(line)
            old_diff.push(line)
          end
        end

        length_o = old_diff.count
        length_n = new_diff.count
        (0..[length_o, length_n].max).each do |i|
          break if i > [length_o, length_n].min

          if /^-.*/.match(old_diff[i]) && !/^\+.*/.match(new_diff[i])
            # tag removed latter to add color syntax
            # ugly way to avoid asymmetry if at display the line takes 2 line on the screen
            insert = "&nbsp;\n"
            new_diff.insert(i, insert)
            length_n += 1
          elsif !/^-.*/.match(old_diff[i]) && /^\+.*/.match(new_diff[i])
            insert = "&nbsp;\n"
            old_diff.insert(i, insert)
            length_o += 1
          end
        end
        { old_diff: old_diff, new_diff: new_diff }
      end

      def escape_once(text)
        text = text.to_s
        text.gsub(HTML_ESCAPE_ONCE_REGEX, HTML_ESCAPE)
      end

      def convert_to_utf8(text)
        detection = ::CharlockHolmes::EncodingDetector.detect(text)
        if detection[:type] == :text
          ::CharlockHolmes::Converter.convert text, detection[:encoding], 'UTF-8'
        else
          'The text contains binary values - cannot display'
        end
      end

      def filter_node_vars(serialized_node)
        # Make a deep copy of the data, so we do not impact oxidized
        data = Marshal.load(Marshal.dump(serialized_node))
        # Make sure we work on strings (Oxidized <= 0.34.1 uses symbols)
        data[:vars] = (data[:vars] || {}).transform_keys(&:to_s)

        configuration = settings.configuration if settings.respond_to?(:configuration)
        hide_node_vars = Array(configuration && configuration[:hide_node_vars]).map(&:to_s)
        if data[:vars].is_a?(Hash) && hide_node_vars&.any?
          hide_node_vars.each do |key|
            data[:vars][key] = '<hidden>' if data[:vars].has_key?(key)
          end
        end
        if data[:vars].is_a?(Hash)
          data[:vars].each_key do |key|
            data[:vars][key] = '<hidden>' if sensitive_node_var?(key)
          end
        end

        data
      end

      def sensitive_node_var?(key)
        name = key.to_s.downcase
        name == 'enable' || name == 'username' ||
          name.match?(/(?:^|_)(?:password|passwd|secret|token|community|passphrase|private_key|api_key|access_key|secret_key|credential)(?:_|\z)/)
      end
    end
  end
end
