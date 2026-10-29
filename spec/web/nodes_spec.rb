require_relative '../spec_helper'
require 'json'

describe Oxidized::API::WebApp do
  include Rack::Test::Methods

  def app
    AuthenticatedWebTestGateway
  end

  before do
    @nodes = mock('Oxidized::Nodes')
    @nodes.stubs(:list).returns(
      [{ name: 'sw4', ip: '10.10.10.10', model: 'ios', time: 'time', mtime: 'mtime' },
       { name: 'sw5', ip: '10.10.10.5',  model: 'ios', time: 'time', mtime: 'mtime' },
       { name: 'sw6', ip: '10.10.10.6',  model: 'ios', time: 'time', mtime: 'mtime' },
       { name: 'sw7', ip: '10.10.10.7',  model: 'ios', time: 'time', mtime: 'mtime', group: 'group1' },
       { name: 'sw8', ip: '10.10.10.8',  model: 'aos', time: 'time', mtime: 'mtime', group: 'group1' },
       { name: 'sw9', ip: '10.10.10.9',  model: 'aos', time: 'time', mtime: 'mtime', group: 'gr/oup1' }]
    )
    app.set(:nodes, @nodes)
    @nodes.stubs(:version).returns([])
    app.set(:configuration, { hide_node_vars: [] })
    AuthenticatedWebTestGateway.prepare
  end

  describe '/nodes.?:format?' do
    it 'shows all nodes' do
      get '/nodes.json'

      _(last_response.ok?).must_equal true
      result = JSON.parse(last_response.body)
      _(result.length).must_equal 6
    end

    it 'hides configured sensitive vars in inventory JSON without mutating Core data' do
      node = {
        name: 'sw4', vars: {
          enable: 'secret-enable', password: 'secret-password', api_key: 'secret-api-key',
          access_key: 'secret-access-key', location: 'lab'
        }
      }
      @nodes.expects(:list).returns([node])
      app.set(:configuration, { hide_node_vars: [] })

      get '/nodes.json'

      _(last_response.ok?).must_equal true
      result = JSON.parse(last_response.body).first
      _(result.dig('vars', 'enable')).must_equal '<hidden>'
      _(result.dig('vars', 'password')).must_equal '<hidden>'
      _(result.dig('vars', 'api_key')).must_equal '<hidden>'
      _(result.dig('vars', 'access_key')).must_equal '<hidden>'
      _(last_response.body).wont_include('secret-api-key')
      _(last_response.body).wont_include('secret-access-key')
      _(result.dig('vars', 'location')).must_equal 'lab'
      _(node.dig(:vars, :enable)).must_equal 'secret-enable'
    end

    it 'shows only data-backed latest backup counts in the inventory overview' do
      now = Time.at(1_750_000_000)
      @nodes.expects(:list).returns(
        [
          { name: 'edge-1', full_name: 'edge-1.example', ip: '192.0.2.1', model: 'ios',
            group: 'core', time: now, mtime: now,
            last: { status: :success, end: now } },
          { name: 'edge-2', full_name: 'edge-2.example', ip: '192.0.2.2', model: 'routeros',
            group: 'branch', time: now, mtime: now,
            last: { status: :no_connection, end: now } },
          { name: 'edge-3', full_name: 'edge-3.example', ip: '192.0.2.3', model: 'ios',
            group: nil, time: 'never', mtime: now },
          { name: 'edge-4', full_name: 'edge-4.example', ip: '192.0.2.4', model: 'ios',
            group: nil, time: now, mtime: now, last: { status: :unknown, end: now } }
        ]
      )

      get '/nodes'

      _(last_response.ok?).must_equal true
      body = last_response.body
      _(body).must_match(/metric-card metric-card-neutral.*?metric-value[^>]*>4</m)
      _(body).must_match(/metric-card metric-card-success.*?metric-value[^>]*>1</m)
      _(body).must_match(/metric-card metric-card-danger.*?metric-value[^>]*>1</m)
      _(body).must_match(/metric-card metric-card-muted.*?metric-value[^>]*>0</m)
      _(body).must_match(/\d+ devices have no stored revisions/)
      _(body).must_include('Most recent Core attempt succeeded')
      _(body).must_include('Most recent Core attempt failed')
    end

    it 'counts Core failure and timelimit results as failed attempts' do
      @nodes.expects(:list).returns(
        [{ name: 'timed-out-device', full_name: 'timed-out-device', ip: '192.0.2.8', model: 'ios',
           group: 'core', last: { status: :timelimit, end: Time.at(1_750_000_000) } },
         { name: 'unsupported-device', full_name: 'unsupported-device', ip: '192.0.2.9', model: 'unknown',
           group: 'core', last: { status: :fail, end: Time.at(1_750_000_000) } }]
      )

      get '/nodes'

      _(last_response.ok?).must_equal true
      _(last_response.body).must_match(/metric-card metric-card-danger.*?metric-value[^>]*>2</m)
      _(last_response.body).must_include('Failed this session')
    end

    it 'displays software versions only when Core supplied them and enables natural version sorting' do
      @nodes.expects(:list).returns(
        [
          { name: 'routeros-old', full_name: 'routeros-old', ip: '192.0.2.1', model: 'routeros',
            vars: { version: 'RouterOS 7.9' }, last: nil },
          { name: 'routeros-new', full_name: 'routeros-new', ip: '192.0.2.2', model: 'routeros',
            vars: {}, last: nil }
        ]
      )

      get '/nodes'

      _(last_response.ok?).must_equal true
      _(last_response.body).must_include('RouterOS 7.9')
      _(last_response.body).must_include('Unknown')
      _(last_response.body).must_include('type: \'version-sort\'')
    end

    it 'lists the five devices with the newest modification timestamps' do
      nodes = (1..6).map do |number|
        timestamp = Time.at(number)
        { name: "change-#{number}", full_name: "change-#{number}.example",
          ip: "192.0.2.#{number}", model: 'ios', group: 'core',
          time: 'never', mtime: timestamp }
      end
      @nodes.expects(:list).returns(nodes)

      get '/nodes'

      _(last_response.ok?).must_equal true
      recent_changes = last_response.body.split('<div class="recent-changes-card">', 2).last
      positions = (2..6).to_a.reverse.map { |number| recent_changes.index("change-#{number}</a>") }
      _(positions).wont_include(nil)
      _(positions).must_equal positions.sort
      _(recent_changes).wont_include('change-1</a>')
    end

    it 'shows an empty state when there are no devices to list' do
      @nodes.expects(:list).returns([])

      get '/nodes'

      _(last_response.ok?).must_equal true
      _(last_response.body).must_match(/metric-card metric-card-neutral.*?metric-value[^>]*>0</m)
      _(last_response.body).must_include('No saved Git revisions are available.')
    end

    it 'shows an empty recent-changes state when listed devices have no modification timestamps' do
      @nodes.expects(:list).returns(
        [{ name: 'untimed-1', full_name: 'untimed-1.example', ip: '192.0.2.10',
           model: 'ios', group: 'core', time: 'never', mtime: nil },
         { name: 'untimed-2', full_name: 'untimed-2.example', ip: '192.0.2.11',
           model: 'ios', group: 'core', time: 'never', mtime: nil }]
      )

      get '/nodes'

      _(last_response.ok?).must_equal true
      _(last_response.body).must_include('No saved Git revisions are available.')
      _(last_response.body).wont_include('class="recent-change-row"')
    end

    it 'reports durable Git revisions after a Core restart without calling the device never backed up' do
      revision_time = Time.utc(2026, 10, 28, 11, 54, 57)
      @nodes.expects(:list).returns(
        [{ name: 'edge-history', full_name: 'core/edge-history', ip: '192.0.2.44', model: 'routeros',
           group: 'core', mtime: 'unknown', last: nil }]
      )
      @nodes.expects(:version).with('edge-history', 'core').returns(
        [{ oid: 'abc123', time: revision_time, message: 'backup' },
         { oid: 'def456', time: revision_time - 86_400, message: 'backup' }]
      )

      get '/nodes.json'

      _(last_response.ok?).must_equal true
      node = JSON.parse(last_response.body).first
      _(node['revision_count']).must_equal 2
      _(node['backup_state']).must_equal 'not_checked_this_session'
      _(node['last_attempt_status']).must_be_nil
      _(Time.parse(node['last_changed_at'])).must_equal revision_time
      _(node['status']).must_equal 'never'
    end

    it 'extracts explicit versions from supported model configuration headers only' do
      webapp = Oxidized::API::WebApp.new
      helpers = webapp.helpers
      _(helpers.send(:parse_software_version, 'routeros', "# 2026-10-24 11:54:57 by RouterOS 7.24.5\r\n/system identity\r\nset name=edge")).must_equal 'RouterOS 7.24.5'
      _(helpers.send(:parse_software_version, 'ios', "version 17.9\nhostname edge")).must_equal 'IOS 17.9'
      _(helpers.send(:parse_software_version, 'nxos', "hostname edge\ninterface Ethernet1/1")).must_equal 'Unknown'
      _(helpers.send(:parse_software_version, 'junos', "## Last commit: 2026-10-01\nJunos: 22.4R3\n")).must_equal 'Junos 22.4R3'
    end

    it 'keys cached software metadata by model as well as the stored revision' do
      revision_time = Time.utc(2026, 10, 29)
      @nodes.expects(:version).with('model-cache-device', 'core').once.returns(
        [{ oid: 'shared-revision', time: revision_time }]
      )
      @nodes.expects(:get_version).with('model-cache-device', 'core', 'shared-revision').twice.returns(
        "# by RouterOS 7.24.5\nversion 17.9\n"
      )
      webapp = Oxidized::API::WebApp.new
      routeros = { name: 'model-cache-device', group: 'core', model: 'routeros', vars: {} }
      ios = { name: 'model-cache-device', group: 'core', model: 'ios', vars: {} }

      _(webapp.helpers.send(:software_version_for, routeros)).must_equal 'RouterOS 7.24.5'
      _(webapp.helpers.send(:software_version_for, ios)).must_equal 'IOS 17.9'
    end
  end

  describe '/nodes/:filter/*' do
    it 'shows all nodes of a group' do
      get '/nodes/group/group1.json'

      _(last_response.ok?).must_equal true
      result = JSON.parse(last_response.body)
      _(result.length).must_equal 2
    end

    it 'hides configured sensitive vars in filtered inventory JSON' do
      @nodes.expects(:list).returns(
        [{ name: 'sw4', group: 'group1', vars: { password: 'secret' } }]
      )
      app.set(:configuration, { hide_node_vars: ['password'] })

      get '/nodes/group/group1.json'

      _(last_response.ok?).must_equal true
      _(JSON.parse(last_response.body).first.dig('vars', 'password')).must_equal '<hidden>'
    end
    it 'shows all nodes of a group with /' do
      get '/nodes/group/gr/oup1.json'

      _(last_response.ok?).must_equal true
      result = JSON.parse(last_response.body)
      _(result.length).must_equal 1
    end
    it 'shows all nodes of a model' do
      get '/nodes/model/ios.json'

      _(last_response.ok?).must_equal true
      result = JSON.parse(last_response.body)
      _(result.length).must_equal 4
    end
    it 'shows all nodes of the default group' do
      get '/nodes/group/default.json'

      _(last_response.ok?).must_equal true
      result = JSON.parse(last_response.body)
      _(result.length).must_equal 3
    end
  end
end
