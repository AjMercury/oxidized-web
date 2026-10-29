require 'sinatra/base'
require 'sinatra/url_for'
require 'tilt/haml'
require 'htmlentities'
require 'charlock_holmes'
require 'base64'
require 'openssl'
require 'uri'
require 'oxidized/web/device_inventory'
module Oxidized
  module API
    require 'oxidized/web/version'

    class WebApp < Sinatra::Base
      helpers Sinatra::UrlForHelper
      set :public_folder, proc { File.join(root, 'public') }
      # attr_quote: use double quotes for HTML attributes. Set explicitly so the
      # output is stable across Haml versions. Haml 7.3.0 changed the default
      # from "'" to '"' (haml/haml#1188); older versions still default to "'".
      set :haml, { escape_html: true, attr_quote: '"' }

      before do
        admin_path = request.path_info.match?(%r{\A/reload(?:\.[^/]+)?\z}) ||
                     request.path_info.start_with?('/admin/devices', '/node/next/')
        if admin_path
          authenticate_admin!
          verify_admin_origin! unless request.request_method == 'GET'
        end
      end

      get '/' do
        redirect url_for('/nodes')
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

          node[:status] = 'never'
          node[:time]   = 'never'
          node[:group]  = 'default' unless node[:group]
          if node[:last]
            node[:status] = node[:last][:status]
            node[:time]   = node[:last][:end]
          end
          node
        end
        out :nodes
      end

      get '/nodes.?:format?' do
        @data = nodes.list.map do |node|
          node = filter_node_vars(node)
          node[:status] = 'never'
          node[:time]   = 'never'
          node[:group]  = 'default' unless node[:group]
          if node[:last]
            node[:status] = node[:last][:status]
            node[:time]   = node[:last][:end]
          end
          node
        end
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
        names = Array(params['devices']).map(&:to_s).uniq
        raise DeviceInventory::Error, 'Select at least one device.' if names.empty?

        case params['operation']
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
        @inventory = DeviceInventory.new(nodes, Oxidized.config)
        @device_fields = @inventory.fields
        @models = available_models
        @device = inventory_nodes.find { |node| node[:name] == params[:name] }
        halt 404, 'device not found' unless @device
        haml :device_edit, layout: true
      end

      post '/admin/devices.?:format?' do
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
        node, @json = route_parse :node
        nodes.next node
        audit_admin!('backup', node)
        redirect url_for('/nodes') unless @json
        @data = 'ok'
        out
      end

      # use this to attach author/email/message to commit
      put '/node/next/?*?/:node' do
        node, @json = route_parse :node
        opt = JSON.parse request.body.read
        nodes.next node, opt
        audit_admin!('backup', node)
        redirect url_for('/nodes') unless @json
        @data = 'ok'
        out
      end

      get '/node/show/:node' do
        node, @json = route_parse :node
        @data = filter_node_vars(nodes.show(node))
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

      def admin_configuration
        settings.configuration if settings.respond_to?(:configuration)
      end

      def authenticate_admin!
        config = admin_configuration || {}
        username = config[:admin_username].to_s
        password = config[:admin_password].to_s
        halt 503, 'Administrator operations are disabled until OXIDIZED_WEB_ADMIN_USERNAME and OXIDIZED_WEB_ADMIN_PASSWORD are configured.' if username.empty? || password.empty?

        header = request.env['HTTP_AUTHORIZATION'].to_s
        encoded = header[/\ABasic\s+(.+)\z/i, 1]
        provided_user = nil
        provided_password = nil
        if encoded
          decoded = Base64.strict_decode64(encoded)
          provided_user, provided_password = decoded.split(':', 2)
        end

        valid_user = secure_compare(provided_user.to_s, username)
        valid_password = secure_compare(provided_password.to_s, password)
        return if valid_user && valid_password

        halt 401, { 'WWW-Authenticate' => 'Basic realm="Oxidized administration", charset="UTF-8"' }, 'Administrator authentication required.'
      rescue ArgumentError
        halt 401, { 'WWW-Authenticate' => 'Basic realm="Oxidized administration", charset="UTF-8"' }, 'Administrator authentication required.'
      end

      def secure_compare(left, right)
        return false unless left.bytesize == right.bytesize

        OpenSSL.fixed_length_secure_compare(left, right)
      end

      def verify_admin_origin!
        origin = request.env['HTTP_ORIGIN']
        referer = request.env['HTTP_REFERER']
        value = origin || referer
        halt 403, 'A same-origin HTTPS request is required.' if value.to_s.empty?

        uri = URI.parse(value)
        halt 403, 'A same-origin HTTPS request is required.' unless uri.scheme == 'https' && uri.host

        expected_host = request.env['HTTP_HOST'].to_s.downcase
        origin_host = uri.host.downcase
        origin_host += ":#{uri.port}" unless uri.port == uri.default_port
        halt 403, 'A same-origin HTTPS request is required.' unless origin_host == expected_host
      rescue URI::InvalidURIError
        halt 403, 'A same-origin HTTPS request is required.'
      end

      def reload_inventory_safely!(expected: nil, removed: nil)
        supports_history_safe_reload = nodes.method(:load).parameters.any? do |kind, name|
          (%i[key keyreq].include?(kind) && name == :clean_obsolete) || kind == :keyrest
        end
        unless supports_history_safe_reload
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

      def validate_model!(model)
        return if model.to_s.empty?
        return if available_models.include?(model.to_s)

        raise DeviceInventory::Error, 'Select an Oxidized model supported by this Core installation.'
      end

      def inventory_nodes
        nodes.list.map do |serialized_node|
          node = filter_node_vars(serialized_node)
          node[:group] ||= 'default'
          node[:status] = node.dig(:last, :status) || 'never'
          node[:time] = node.dig(:last, :end) || 'never'
          node
        end
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
        config = admin_configuration || {}
        username = config[:admin_username].to_s.gsub(/[\r\n]/, '_')
        device = name.to_s.gsub(/[\r\n]/, '_')
        logger.info("admin_audit action=#{action} admin=#{username} device=#{device}")
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
