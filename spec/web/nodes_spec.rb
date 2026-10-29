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

    it 'shows completed attempt totals separately from each device latest state' do
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
      core_stats = Struct.new(:successes, :failures)
      core_node = Struct.new(:stats)
      @nodes.stubs(:each).multiple_yields(
        core_node.new(core_stats.new(2, 0)), core_node.new(core_stats.new(1, 1)),
        core_node.new(core_stats.new(0, 0)), core_node.new(core_stats.new(0, 0))
      )

      get '/nodes'

      _(last_response.ok?).must_equal true
      body = last_response.body
      _(body).must_match(/metric-card metric-card-neutral.*?metric-value[^>]*>4</m)
      _(body).must_match(/metric-card metric-card-success.*?metric-value[^>]*>3</m)
      _(body).must_match(/metric-card metric-card-danger.*?metric-value[^>]*>1</m)
      _(body).must_match(/metric-card metric-card-muted.*?metric-value[^>]*>2</m)
      _(body).must_include('Backup coverage')
      _(body).must_include('completed attempts this session')
      _(body).must_include('State per device; Core resets it on restart')
    end

    it 'counts Core failure and timelimit results as failed attempts' do
      @nodes.expects(:list).returns(
        [{ name: 'timed-out-device', full_name: 'timed-out-device', ip: '192.0.2.8', model: 'ios',
           group: 'core', last: { status: :timelimit, end: Time.at(1_750_000_000) } },
         { name: 'unsupported-device', full_name: 'unsupported-device', ip: '192.0.2.9', model: 'unknown',
           group: 'core', last: { status: :fail, end: Time.at(1_750_000_000) } }]
      )
      core_stats = Struct.new(:successes, :failures)
      core_node = Struct.new(:stats)
      @nodes.stubs(:each).multiple_yields(
        core_node.new(core_stats.new(0, 1)), core_node.new(core_stats.new(0, 1))
      )

      get '/nodes'

      _(last_response.ok?).must_equal true
      _(last_response.body).must_match(/metric-card metric-card-danger.*?metric-value[^>]*>2</m)
      _(last_response.body).must_include('Failed attempts this session')
    end

    it 'summarizes backup health from Core attempts and keeps attempt and success times distinct' do
      attempt_time = Time.at(1_750_000_100)
      success_time = Time.at(1_750_000_000)
      nodes = [
        { name: 'success-edge', full_name: 'core/success-edge', ip: '192.0.2.21', model: 'ios', group: 'core',
          last: { status: :success, end: attempt_time } },
        { name: 'failed-edge', full_name: 'core/failed-edge', ip: '192.0.2.22', model: 'routeros', group: 'core',
          last: { status: :no_auth, end: attempt_time } },
        { name: 'running-edge', full_name: 'core/running-edge', ip: '192.0.2.23', model: 'ios', group: 'core',
          last: { status: :running, end: attempt_time } },
        { name: 'queued-edge', full_name: 'core/queued-edge', ip: '192.0.2.24', model: 'ios', group: 'core',
          last: { status: :queued, end: attempt_time } },
        { name: 'stored-edge', full_name: 'core/stored-edge', ip: '192.0.2.25', model: 'ios', group: 'core' },
        { name: 'never-edge', full_name: 'core/never-edge', ip: '192.0.2.26', model: 'ios', group: 'core' }
      ]
      @nodes.expects(:list).returns(nodes)
      revisions = {
        'success-edge' => [{ oid: 'success-revision', time: success_time }],
        'failed-edge' => [{ oid: 'failed-revision', time: success_time }],
        'running-edge' => [], 'queued-edge' => [],
        'stored-edge' => [{ oid: 'stored-revision', time: success_time }],
        'never-edge' => []
      }
      revisions.each do |name, history|
        @nodes.stubs(:version).with(name, 'core').returns(history)
      end

      stats_class = Struct.new(:success_history) do
        def get(status)
          status == :success ? success_history : []
        end
      end
      core_node = Struct.new(:name, :stats)
      success_stats = stats_class.new([{ end: attempt_time }])
      failed_stats = stats_class.new([{ end: success_time }])
      empty_stats = stats_class.new([])
      @nodes.stubs(:each).multiple_yields(
        core_node.new('success-edge', success_stats), core_node.new('failed-edge', failed_stats),
        core_node.new('running-edge', empty_stats), core_node.new('queued-edge', empty_stats),
        core_node.new('stored-edge', empty_stats), core_node.new('never-edge', empty_stats)
      )

      get '/nodes/stats'

      _(last_response.ok?).must_equal true
      body = last_response.body
      _(body).must_match(/metric-card metric-card-neutral.*?metric-value[^>]*>6</m)
      _(body).must_match(/metric-card metric-card-success.*?metric-value[^>]*>1</m)
      _(body).must_match(/metric-card metric-card-danger.*?metric-value[^>]*>1</m)
      _(body).must_include('1 running · 1 queued')
      _(body).must_match(/metric-card metric-card-warning.*?metric-value[^>]*>2</m)
      _(body).must_match(/metric-card metric-card-muted.*?metric-value[^>]*>3</m)
      _(body).must_include('Authentication failed')
      _(body).must_include('not checked this session')
      failed_row = body.scan(%r{<tr[^>]*>.*?</tr>}m).find { |row| row.include?('failed-edge') }
      _(failed_row).wont_be_nil
      attempt_position = failed_row.index("epoch=\"#{attempt_time.to_i}\"")
      success_position = failed_row.index("epoch=\"#{success_time.to_i}\"")
      _(attempt_position).wont_be_nil
      _(success_position).wont_be_nil
      _(attempt_position < success_position).must_equal true
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

  describe '/nodes/recent' do
    it 'shows the latest saved revision and its available comparison counts' do
      revision_time = Time.utc(2026, 10, 29, 9, 30)
      @nodes.expects(:list).returns(
        [{ name: 'edge-1', full_name: 'core/edge-1', ip: '192.0.2.12', model: 'ios', group: 'core', vars: {} }]
      )
      @nodes.expects(:version).with('edge-1', 'core').returns(
        [{ oid: 'new-revision', time: revision_time }, { oid: 'old-revision', time: revision_time - 3600 }]
      )
      @nodes.expects(:get_diff).with('edge-1', 'core', 'new-revision', 'old-revision').returns(
        { patch: "@@ -1 +1 @@\n-old\n+new\n", stat: [1, 1] }
      )

      get '/nodes/recent'

      _(last_response.ok?).must_equal true
      _(last_response.body).must_include('Recent changes')
      _(last_response.body).must_include('new-revision')
      _(last_response.body).must_include('>1</td>')
      _(last_response.body).must_include('/node/version/diffs?')
      _(last_response.body).must_include('All vendors')
      _(last_response.body).wont_include('diff --git')
    end

    it 'shows every revision in timestamp order and compares each change with its predecessor' do
      @nodes.expects(:list).returns(
        [{ name: 'edge-1', full_name: 'core/edge-1', ip: '192.0.2.12', model: 'ios', group: 'core', vars: {} },
         { name: 'edge-2', full_name: 'branch/edge-2', ip: '192.0.2.13', model: 'routeros', group: 'branch', vars: {} }]
      )
      @nodes.expects(:version).with('edge-1', 'core').returns(
        [{ oid: 'edge1-new', time: Time.at(500) }, { oid: 'edge1-middle', time: Time.at(300) },
         { oid: 'edge1-old', time: Time.at(100) }]
      )
      @nodes.expects(:version).with('edge-2', 'branch').returns(
        [{ oid: 'edge2-new', time: Time.at(400) }, { oid: 'edge2-old', time: Time.at(200) }]
      )
      @nodes.expects(:get_diff).with('edge-1', 'core', 'edge1-new', 'edge1-middle').returns(
        { patch: '', stat: [1, 0] }
      )
      @nodes.expects(:get_diff).with('edge-1', 'core', 'edge1-middle', 'edge1-old').returns(
        { patch: '', stat: [2, 3] }
      )
      @nodes.expects(:get_diff).with('edge-2', 'branch', 'edge2-new', 'edge2-old').returns(
        { patch: '', stat: [4, 1] }
      )

      get '/nodes/recent'

      _(last_response.ok?).must_equal true
      rows = last_response.body.scan(%r{<tr(?=[^>]*class="[^"]*recent-change-row)[^>]*>.*?</tr>}m)
      revision_ids = rows.map { |row| row[%r{<code class="revision-id">(.*?)</code>}m, 1] }
      _(revision_ids).must_equal %w[edge1-new edge2-new edge1-midd edge2-old edge1-old]
      _(rows[2]).must_include('title="edge1-middle"')
      _(rows[2]).must_include('oid=edge1-middle')
      _(rows[0]).must_include('<td class="text-end">1</td>')
      _(rows[0]).must_include('<td class="text-end">0</td>')
      _(rows[2]).must_include('<td class="text-end">2</td>')
      _(rows[2]).must_include('<td class="text-end">3</td>')
      _(rows[4]).must_include('No previous revision')
    end

    it 'uses Core nil group for history reads while showing the default group label' do
      @nodes.expects(:list).returns(
        [{ name: 'standalone-edge', full_name: 'standalone-edge', ip: '192.0.2.14', model: 'ios', vars: {} }]
      )
      @nodes.expects(:version).with('standalone-edge', nil).returns(
        [{ oid: 'standalone-new', time: Time.at(600) }, { oid: 'standalone-old', time: Time.at(300) }]
      )
      @nodes.expects(:get_diff).with('standalone-edge', nil, 'standalone-new', 'standalone-old')
            .returns({ patch: '', stat: [1, 0] })

      get '/nodes/recent'

      _(last_response.ok?).must_equal true
      _(last_response.body).must_include('standalone-edge')
      _(last_response.body).must_include('node=standalone-edge&amp;group&amp;oid=standalone-new')
      _(last_response.body).wont_include('group=default')
    end

    it 'limits Recent Changes rows and diff-stat reads to the newest one hundred revisions' do
      revisions = 125.times.map { |index| { oid: "limit-#{index}", time: Time.at(10_000 - index) } }
      @nodes.expects(:list).returns(
        [{ name: 'edge-limit', full_name: 'core/edge-limit', ip: '192.0.2.15', model: 'ios', group: 'core', vars: {} }]
      )
      @nodes.expects(:version).with('edge-limit', 'core').returns(revisions)
      @nodes.expects(:get_diff).times(100).returns({ patch: '', stat: [1, 0] })

      get '/nodes/recent'

      _(last_response.ok?).must_equal true
      rows = last_response.body.scan(/<tr(?=[^>]*class="[^"]*recent-change-row)[^>]*>/m)
      _(rows.length).must_equal 100
      _(last_response.body).must_include('Showing the 100 most recent revisions')
      _(last_response.body).must_include('v125')
      _(last_response.body).must_include('v26')
      _(last_response.body).wont_include('v25')
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
