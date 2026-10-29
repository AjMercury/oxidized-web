require_relative '../spec_helper'

describe 'manual backup API' do
  include Rack::Test::Methods

  def app
    AuthenticatedWebTestGateway
  end

  before do
    AuthenticatedWebTestGateway.prepare
    @nodes = mock('Core bounded queue')
    app.set(:nodes, @nodes)
  end

  it 'queues all configured nodes server-side without receiving visible rows' do
    @nodes.expects(:queue_backups).with(nil).returns([{ name: 'off-page-router', state: 'queued' }])
    post '/admin/backups.json', all: 'true'
    _(last_response.status).must_equal 202
    _(JSON.parse(last_response.body)['devices'].first['state']).must_equal 'queued'
  end

  it 'queues only the unique selected devices' do
    @nodes.expects(:queue_backups).with(%w[one two]).returns([])
    post '/admin/backups.json', devices: %w[one two one]
    _(last_response.status).must_equal 202
  end

  it 'returns actual Core state without turning queued into succeeded' do
    @nodes.expects(:backup_status).returns([{ name: 'one', state: 'running' }])
    get '/admin/backups.json'
    _(JSON.parse(last_response.body)['devices'].first['state']).must_equal 'running'
  end

  it 'requires the Core queue API instead of inferring completion from timestamps' do
    app.set(:nodes, Object.new)
    post '/admin/backups.json', all: 'true'
    _(last_response.status).must_equal 409
    get '/admin/backups.json'
    _(last_response.status).must_equal 409
  end

  it 'queues a grouped legacy request using the Core node name' do
    @nodes.expects(:queue_backups).with(['one']).returns([])
    post '/node/next/lab/one.json'
    _(last_response.status).must_equal 200
  end

  it 'denies viewers and missing CSRF before calling Core' do
    @nodes.expects(:queue_backups).never
    AuthenticatedWebTestGateway.as_role(:viewer)
    post '/admin/backups.json', all: 'true'
    _(last_response.status).must_equal 403
    AuthenticatedWebTestGateway.prepare
    post '/admin/backups.json', { all: 'true' }, 'HTTP_X_CSRF_TOKEN' => 'invalid'
    _(last_response.status).must_equal 403
  end

  it 'forwards grouped PUT commit metadata through the shared queue' do
    data = { 'user' => 'synthetic', 'email' => 'qa@example.invalid', 'message' => 'manual collection' }
    @nodes.expects(:queue_backups).with(['one'], data).returns([])
    put '/node/next/lab/one.json', data.to_json, 'CONTENT_TYPE' => 'application/json'
    _(last_response.status).must_equal 200
  end

  it 'rejects an empty selection' do
    @nodes.stubs(:queue_backups)
    post '/admin/backups.json', devices: []
    _(last_response.status).must_equal 422
  end
end
