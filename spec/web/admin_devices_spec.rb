require_relative '../spec_helper'
require 'tmpdir'

class AdminDevicesSpecCsv
  attr_reader :file, :delimiter, :map, :vars_map

  def initialize(file, delimiter, map, vars_map, gpg)
    @file = file
    @delimiter = delimiter
    @map = map
    @vars_map = vars_map
    @gpg = gpg
  end

  def gpg?
    @gpg
  end
end
AdminDevicesSpecSource = Struct.new(:csv)
AdminDevicesSpecConfig = Struct.new(:source)

class AdminDevicesFakeNodes
  attr_reader :source, :reload_history_options, :backup_requests

  def initialize(file)
    @file = file
    @source = 'csv'
    @reload_history_options = []
    @backup_requests = []
    @current = []
  end

  def load(_node_want = nil, clean_obsolete: true)
    @reload_history_options << clean_obsolete
    @current = File.binread(@file).lines.filter_map do |line|
      next if line.match?(/^\s*#/) || line.strip.empty?

      fields = line.chomp.split(':', -1)
      { name: fields[0], full_name: fields[0], ip: fields[2], model: fields[1],
        group: fields[3], last: nil, vars: { 'enable' => fields[6], 'description' => fields[7] } }
    end
  end

  def list
    @current
  end

  def next(node)
    @backup_requests << node
  end
end

describe 'administrator device management' do
  include Rack::Test::Methods

  def app
    AuthenticatedWebTestGateway
  end

  def admin_headers
    {
      'HTTP_AUTHORIZATION' => "Basic #{Base64.strict_encode64('admin:correct-horse')}",
      'HTTP_ORIGIN' => 'https://example.org'
    }
  end

  before do
    @directory = Dir.mktmpdir('oxidized-web-admin')
    @path = File.join(@directory, 'router.db')
    File.binwrite(@path, "# preserved comment\n")
    csv = AdminDevicesSpecCsv.new(
      @path, /:/, { name: 0, model: 1, ip: 2, group: 3, username: 4, password: 5 },
      { enable: 6, description: 7 }, false
    )
    Oxidized.stubs(:config).returns(AdminDevicesSpecConfig.new(AdminDevicesSpecSource.new(csv)))
    @nodes = AdminDevicesFakeNodes.new(@path)
    app.set(:nodes, @nodes)
    app.set(:configuration, {
              hide_node_vars: %w[enable password],
              admin_username: 'admin', admin_password: 'correct-horse',
              viewer_username: 'viewer', viewer_password: 'read-only'
            })
    AuthenticatedWebTestGateway.prepare
  end

  after do
    FileUtils.remove_entry(@directory) if File.directory?(@directory)
  end

  it 'shows a mapped CSV form and live device inventory only to an authenticated administrator' do
    AuthenticatedWebTestGateway.clear
    get '/admin/devices'
    _(last_response.status).must_equal 302

    AuthenticatedWebTestGateway.prepare
    get '/admin/devices', {}, admin_headers

    _(last_response.ok?).must_equal true
    _(last_response.body).must_include('Device management')
    _(last_response.body).must_include('Management IP / FQDN')
    _(last_response.body).must_include('Search installed Core models')
    _(last_response.body).must_include('All vendors')
    _(last_response.body).must_include('Cisco')
    _(last_response.body).must_include('/images/vendors/cisco.svg')
    _(last_response.body).must_match(%r{</select>\s*<form[^>]*id="bulkDevices"}m)
  end

  it 'explains an incomplete CSV mapping instead of rendering an empty Add Device form' do
    csv = AdminDevicesSpecCsv.new(@path, /:/, { name: 0, model: 1 }, { username: 4 }, false)
    Oxidized.stubs(:config).returns(AdminDevicesSpecConfig.new(AdminDevicesSpecSource.new(csv)))

    get '/admin/devices', {}, admin_headers

    _(last_response.ok?).must_equal true
    _(last_response.body).must_include('source.csv.map is missing required Core fields: ip')
    _(last_response.body).must_include('Check the actual column order')
    _(last_response.body).must_include('Example only: replace each placeholder')
    _(last_response.body).wont_include('class="device-form-card"')
    _(last_response.body).wont_include('name="password"')
  end

  it 'identifies a non-CSV source as read-only without showing CSV mapping instructions' do
    @nodes.stubs(:source).returns('netbox')

    get '/admin/devices', {}, admin_headers

    _(last_response.ok?).must_equal true
    _(last_response.body).must_include('The configured inventory is read-only in Web')
    _(last_response.body).must_include('Device management supports only a CSV inventory source.')
    _(last_response.body).wont_include('source.csv.map is missing required Core fields')
    _(last_response.body).wont_include('name: &lt;column index&gt;')
    _(last_response.body).wont_include('class="device-form-card"')
  end

  it 'explains why device management is disabled when administrator credentials are missing' do
    @auth_store = Oxidized::API::UserStore.new(File.join(@directory, 'empty.sqlite3'))
    app.set(:auth_store, @auth_store)
    get '/login'
    _(last_response.ok?).must_equal true
    _(last_response.body).must_include('No accounts exist yet')
    _(last_response.body).must_include('oxidized-web-user bootstrap-admin')
  end

  it 'allows a configured read-only role to view inventory but denies writes' do
    AuthenticatedWebTestGateway.as_role(:viewer)
    viewer_headers = { 'HTTP_AUTHORIZATION' => "Basic #{Base64.strict_encode64('viewer:read-only')}" }
    get '/admin/devices', {}, viewer_headers
    _(last_response.ok?).must_equal true
    _(last_response.body).must_include('read-only access')
    _(last_response.body).wont_include('id="bulkDevices"')

    post '/admin/devices.json', { name: 'reader-write', model: 'ios', ip: '192.0.2.3' }, viewer_headers
    _(last_response.status).must_equal 403
  end

  it 'protects source reload routes with a format suffix' do
    AuthenticatedWebTestGateway.clear
    @nodes.expects(:load).never

    post '/reload.json'

    _(last_response.status).must_equal 401
  end

  it 'persists a device, safely reloads Core, and omits credentials from the response' do
    post '/admin/devices.json', {
      name: 'edge-1', model: 'ios', ip: '192.0.2.1', group: 'branch',
      username: 'collector', password: 'private-password', enable: 'private-enable',
      description: 'Synthetic test router'
    }, admin_headers

    _(last_response.status).must_equal 201
    _(last_response.body).wont_include('private-password')
    _(last_response.body).wont_include('private-enable')
    _(File.binread(@path)).must_include('edge-1:ios:192.0.2.1:branch:collector:private-password:private-enable:Synthetic test router')
    _(@nodes.reload_history_options).must_equal [false]
    _(@nodes.list.first[:name]).must_equal 'edge-1'
  end

  it 'rejects duplicate devices without writing or reloading' do
    File.binwrite(@path, "# comment\nedge-1:ios:192.0.2.1:::::\n")
    original = File.binread(@path)

    post '/admin/devices.json', { name: 'edge-1', model: 'ios', ip: '192.0.2.1' }, admin_headers

    _(last_response.status).must_equal 409
    _(File.binread(@path)).must_equal original
    _(@nodes.reload_history_options).must_be_empty
  end

  it 'updates and deletes devices from the configured CSV source' do
    File.binwrite(@path, "# keep\nedge-1:ios:192.0.2.1:core:reader:old-secret:enable-old:description\n")
    @nodes.load(nil, clean_obsolete: false)

    post '/admin/devices/edge-1.json', { ip: '192.0.2.9', password: '' }, admin_headers
    _(last_response.ok?).must_equal true
    _(File.binread(@path)).must_include('edge-1:ios:192.0.2.9:core:reader:old-secret')
    _(@nodes.reload_history_options.last).must_equal false

    post '/admin/devices/edge-1.json', { new_name: 'edge-renamed' }, admin_headers
    _(last_response.ok?).must_equal true
    _(File.binread(@path)).must_include('edge-renamed:ios:192.0.2.9:core:reader:old-secret')
    _(@nodes.list.first[:name]).must_equal 'edge-renamed'

    post '/admin/devices/edge-renamed/delete.json', {}, admin_headers
    _(last_response.ok?).must_equal true
    _(File.binread(@path)).must_equal "# keep\n"
    _(@nodes.list).must_be_empty
  end

  it 'rejects updates that clear the required model or management address' do
    original = "edge-1:ios:192.0.2.1:::::\n"
    File.binwrite(@path, original)
    @nodes.load(nil, clean_obsolete: false)

    post '/admin/devices/edge-1.json', { model: '' }, admin_headers
    _(last_response.status).must_equal 422
    _(File.binread(@path)).must_equal original

    post '/admin/devices/edge-1.json', { ip: '' }, admin_headers
    _(last_response.status).must_equal 422
    _(File.binread(@path)).must_equal original
  end

  it 'rejects renaming a device to an existing hostname without changing inventory' do
    original = "one:ios:192.0.2.1:::::\ntwo:routeros:192.0.2.2:::::\n"
    File.binwrite(@path, original)
    @nodes.load(nil, clean_obsolete: false)

    post '/admin/devices/one.json', { new_name: 'two' }, admin_headers

    _(last_response.status).must_equal 409
    _(File.binread(@path)).must_equal original
    _(@nodes.reload_history_options).must_equal [false]
  end

  it 'rejects cross-origin writes and unsupported models' do
    post '/admin/devices.json', { name: 'edge-1', model: '../ios', ip: '192.0.2.1' },
         'HTTP_AUTHORIZATION' => admin_headers['HTTP_AUTHORIZATION'],
         'HTTP_ORIGIN' => 'https://attacker.example'
    _(last_response.status).must_equal 403

    post '/admin/devices.json', { name: 'edge-1', model: '../ios', ip: '192.0.2.1' }, admin_headers
    _(last_response.status).must_equal 422
    _(File.binread(@path)).must_equal "# preserved comment\n"
  end

  it 'rejects writes with an insecure same-host origin or a different port' do
    insecure_origin = admin_headers.merge('HTTP_ORIGIN' => 'http://example.org')
    post '/admin/devices.json', { name: 'edge-1', model: 'ios', ip: '192.0.2.1' }, insecure_origin
    _(last_response.status).must_equal 403

    wrong_port = admin_headers.merge('HTTP_ORIGIN' => 'https://example.org:444')
    post '/admin/devices.json', { name: 'edge-1', model: 'ios', ip: '192.0.2.1' }, wrong_port
    _(last_response.status).must_equal 403

    post '/admin/devices.json', { name: 'edge-1', model: 'ios', ip: '192.0.2.1' },
         'HTTP_AUTHORIZATION' => admin_headers['HTTP_AUTHORIZATION'], 'HTTP_ORIGIN' => ''
    _(last_response.status).must_equal 403
  end

  it 'does not allow legacy GET reload or backup routes to mutate state' do
    @nodes.expects(:load).never
    @nodes.expects(:next).never

    get '/reload'
    _(last_response.status).must_equal 404
    get '/node/next/edge-1'
    _(last_response.status).must_equal 404
  end

  it 'queues bulk backups and deletes selected CSV records in one history-safe reload' do
    File.binwrite(@path, "one:ios:192.0.2.1:::::\ntwo:routeros:192.0.2.2:::::\n")
    @nodes.load(nil, clean_obsolete: false)

    post '/admin/devices/bulk.json', { operation: 'backup', 'devices[]' => %w[one two] }, admin_headers
    _(last_response.ok?).must_equal true
    _(@nodes.backup_requests).must_equal %w[one two]

    post '/admin/devices/bulk.json', { operation: 'delete', 'devices[]' => %w[one two] }, admin_headers
    _(last_response.ok?).must_equal true
    _(File.binread(@path)).must_equal ''
    _(@nodes.reload_history_options.last).must_equal false
  end

  it 'rejects bulk requests with unknown devices before any backup or deletion' do
    original = "one:ios:192.0.2.1:::::\n"
    File.binwrite(@path, original)
    @nodes.load(nil, clean_obsolete: false)

    post '/admin/devices/bulk.json', { operation: 'backup', 'devices[]' => %w[one missing] }, admin_headers
    _(last_response.status).must_equal 409
    _(@nodes.backup_requests).must_be_empty

    post '/admin/devices/bulk.json', { operation: 'delete', 'devices[]' => %w[one missing] }, admin_headers
    _(last_response.status).must_equal 404
    _(File.binread(@path)).must_equal original
  end

  it 'rolls back a single delete when Core still reports the device' do
    original = "one:ios:192.0.2.1:::::\n"
    File.binwrite(@path, original)
    @nodes.load(nil, clean_obsolete: false)
    def @nodes.load(*, **)
      # Simulate Core failing to refresh the in-memory inventory.
    end

    post '/admin/devices/one/delete.json', {}, admin_headers

    _(last_response.status).must_equal 500
    _(File.binread(@path)).must_equal original
  end

  it 'assigns a group to selected devices through the configured CSV source' do
    File.binwrite(@path, "one:ios:192.0.2.1:old:::::\ntwo:routeros:192.0.2.2:old:::::\n")
    @nodes.load(nil, clean_obsolete: false)

    post '/admin/devices/bulk.json', { operation: 'group', group: 'branch/east', 'devices[]' => %w[one two] }, admin_headers

    _(last_response.ok?).must_equal true
    _(File.binread(@path)).must_include('one:ios:192.0.2.1:branch/east:')
    _(File.binread(@path)).must_include('two:routeros:192.0.2.2:branch/east:')
    _(@nodes.reload_history_options.last).must_equal false
  end

  it 'rolls back a bulk delete when Core still reports any selected device' do
    original = "one:ios:192.0.2.1:::::\ntwo:routeros:192.0.2.2:::::\n"
    File.binwrite(@path, original)
    @nodes.load(nil, clean_obsolete: false)
    def @nodes.load(*, **)
      # Simulate Core failing to refresh the in-memory inventory.
    end

    post '/admin/devices/bulk.json', { operation: 'delete', 'devices[]' => %w[one two] }, admin_headers

    _(last_response.status).must_equal 500
    _(File.binread(@path)).must_equal original
  end

  it 'exports only non-credential inventory and status fields' do
    File.binwrite(@path, "one:ios:192.0.2.1:core:reader:private-password:private-enable:description\n")
    @nodes.load(nil, clean_obsolete: false)

    get '/admin/devices/export.csv', {}, admin_headers

    _(last_response.ok?).must_equal true
    _(last_response.body).must_include('one,192.0.2.1,ios,core')
    _(last_response.body).wont_include('private-password')
    _(last_response.body).wont_include('private-enable')
  end
end
