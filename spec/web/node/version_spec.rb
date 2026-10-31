require_relative '../../spec_helper'

describe Oxidized::API::WebApp do
  include Rack::Test::Methods

  def app
    AuthenticatedWebTestGateway
  end

  before do
    @nodes = mock('Oxidized::Nodes')
    app.set(:nodes, @nodes)
    AuthenticatedWebTestGateway.prepare
  end

  describe 'get /node/version.?:format?' do
    before do
      @versions = [
        { oid: "C006", time: Time.parse("2025-02-05 19:49:00 +0100") },
        { oid: "C003", time: Time.parse("2025-02-05 19:03:00 +0100") },
        { oid: "C001", time: Time.parse("2025-02-05 19:01:00 +0100") }
      ]
    end

    it 'fetches all versions of a node without a group' do
      @nodes.expects(:version).with('sw5', nil).returns(@versions)

      get '/node/version?node_full=sw5'
      _(last_response.ok?).must_equal true
      _(last_response.body).must_include('<span class="version-chip">v3</span>')
      _(last_response.body).must_include('<td data-order="3"><div class="version-number">')
      _(last_response.body).must_include("stateLoadParams: function(_settings, state) { state.order = [[0, 'desc']]; }")
      _(last_response.body).must_include(
        "<td class=\"time\" data-order=\"1738781340\" epoch=\"1738781340\">2025-02-05 19:49:00 +0100</td>"
      )

      _(last_response.body.include?(
          "href=\"/node/version/view?node=sw5&amp;group=&amp;oid=C006&amp;" \
          "epoch=1738781340&amp;num=3\""
        )).must_equal true
      _(last_response.body.include?(
          "href=\"/node/version/diffs?node=sw5&amp;group=&amp;oid=C006&amp;" \
          "epoch=1738781340&amp;num=3\""
        )).must_equal true
      _(last_response.body.include?(
          "href=\"/node/version/view?node=sw5&amp;group=&amp;oid=C001&amp;" \
          "epoch=1738778460&amp;num=1\""
        )).must_equal true
      # Compare to the version previous 1 is not possible, so don't display it
      _(last_response.body.include?(
          "href=\"/node/version/diffs?node=sw5&amp;group=&amp;oid=C001&amp;" \
          "epoch=1738778460&amp;num=1\""
        )).must_equal false
      _(last_response.body.scan('class="latest-chip"').length).must_equal 1
    end

    it 'fetches all versions of a node with a group' do
      @nodes.expects(:version).with('sw5', 'group1').returns(@versions)

      get '/node/version?node_full=group1/sw5'
      _(last_response.ok?).must_equal true
      _(last_response.body).must_include('<span class="version-chip">v3</span>')
      _(last_response.body).must_include(
        "<td class=\"time\" data-order=\"1738781340\" epoch=\"1738781340\">2025-02-05 19:49:00 +0100</td>"
      )
      _(last_response.body).must_include(
        'href="/node/version/view?node=sw5&amp;group=group1&amp;oid=C006&amp;epoch=1738781340&amp;num=3"'
      )
      _(last_response.body).must_include(
        'href="/node/version/diffs?node=sw5&amp;group=group1&amp;oid=C006&amp;epoch=1738781340&amp;num=3"'
      )
    end

    it 'shows the Git author for each revision and falls back when author metadata is absent' do
      revisions = [
        { oid: 'C006', time: Time.parse('2025-02-05 19:49:00 +0100'),
          author: { name: 'Device <Operator>', email: 'operator@example.net" onclick="alert(1)' } },
        { oid: 'C003', time: Time.parse('2025-02-05 19:03:00 +0100'), 'author' => { 'name' => 'Legacy Operator' } },
        { oid: 'C001', time: Time.parse('2025-02-05 19:01:00 +0100') }
      ]
      @nodes.expects(:version).with('sw5', nil).returns(revisions)

      get '/node/version?node_full=sw5'

      _(last_response.ok?).must_equal true
      _(last_response.body).must_include('<th>Author</th>')
      _(last_response.body).must_include('Device &lt;Operator&gt;')
      _(last_response.body).must_include('title="operator@example.net&quot; onclick=&quot;alert(1)"')
      _(last_response.body).must_include('>Legacy Operator</td>')
      _(last_response.body).must_match(%r{<td class="author-cell"[^>]*>Unknown</td>})
    end

    it 'fetches all versions of a node with a group with /' do
      @nodes.expects(:version).with('sw5', 'gr/oup1').returns(@versions)

      get '/node/version?node_full=gr/oup1/sw5'
      _(last_response.ok?).must_equal true
      _(last_response.body).must_include('<span class="version-chip">v3</span>')
      _(last_response.body).must_include(
        "<td class=\"time\" data-order=\"1738781340\" epoch=\"1738781340\">2025-02-05 19:49:00 +0100</td>"
      )
    end

    it 'returns 200 when node_full is absent (no NoMethodError)' do
      @nodes.expects(:version).with('', nil).returns([])

      get '/node/version'
      _(last_response.ok?).must_equal true
    end
  end

  describe 'get /node/version/view.?:format?' do
    it 'fetches a previous version from git' do
      @nodes.expects(:get_version).with('sw5', nil, 'c8aa93cab5').returns('Old configuration of sw5')

      get '/node/version/view?node=sw5&group=&oid=c8aa93cab5&epoch=1738781340&num=2'
      _(last_response.ok?).must_equal true
      _(last_response.body.include?('Old configuration of sw5')).must_equal true
      _(last_response.body).must_include(
        'href="/node/version/view?node=sw5&amp;group=&amp;oid=c8aa93cab5&amp;epoch=1738781340&amp;num=2&amp;format=text"'
      )
      # The test needs to pass in any timezone, so we use Time.parse to get the
      # right string
      _(last_response.body).must_match(/<span class="time" epoch="1738781340">/)
    end

    it 'does not display binary content' do
      @nodes.expects(:get_version).with('sw5', nil, 'c8aa93cab5').returns("\xff\x42 binary content\x00")

      get '/node/version/view?node=sw5&group=&oid=c8aa93cab5&epoch=1738781340&num=2'
      _(last_response.ok?).must_equal true
      _(last_response.body.include?('cannot display')).must_equal true
    end

    it 'fetches a git-version when using a group containing /' do
      @nodes.expects(:get_version).with('sw5', 'my/group', 'c8aa93cab5').returns('Old configuration of sw5')

      get '/node/version/view?node=sw5&group=my/group&oid=c8aa93cab5&epoch=1738781340&num=2'
      _(last_response.ok?).must_equal true
      _(last_response.body.include?('Old configuration of sw5')).must_equal true
    end

    it 'does not encode html-chars in text-format' do
      configuration = "text &/<> \n ascii;"
      @nodes.expects(:get_version).with('sw5', nil, 'c8aa93cab5').returns(configuration)
      get '/node/version/view?node=sw5&group=&oid=c8aa93cab5&epoch=1738781340&num=2&format=text'

      _(last_response.ok?).must_equal true
      _(last_response.body).must_equal configuration
    end

    it 'does not encode html-chars in json-format' do
      configuration = "text &/<> \n ascii;"
      @nodes.expects(:get_version).with('sw5', nil, 'c8aa93cab5').returns(configuration)
      get '/node/version/view?node=sw5&group=&oid=c8aa93cab5&epoch=1738781340&num=2&format=json'

      _(last_response.ok?).must_equal true
      _(last_response.body).must_equal '["text &/<> \n"," ascii;"]'
    end

    it 'returns 200 when group param is absent (no NoMethodError)' do
      @nodes.expects(:get_version).with('sw5', nil, 'c8aa93cab5').returns('Old configuration of sw5')

      get '/node/version/view?node=sw5&oid=c8aa93cab5&epoch=1738781340&num=2'
      _(last_response.ok?).must_equal true
      _(last_response.body.include?('Old configuration of sw5')).must_equal true
    end
  end

  describe 'get /node/version/diffs' do
    it 'diffs a version with the latest configuration' do
      @versions = [
        { oid: "C006", time: Time.parse("2025-02-05 19:49:00 +0100") },
        { oid: "C003", time: Time.parse("2025-02-05 19:03:00 +0100") },
        { oid: "C001", time: Time.parse("2025-02-05 19:01:00 +0100") }
      ]
      @diff = { patch: "diff --git a/sw5 b/sw5\n" \
                       "index C006..C003 100644\n" \
                       "--- a/sw5\n" \
                       "+++ b/sw5\n" \
                       "@@ -38,12 +38,12 @@ some_line\n " \
                       "unchanged line\n" \
                       "-changed line old\n" \
                       "+changed line new1\n" \
                       "+changed line new2\n " \
                       "\n " \
                       "unchanged line\n",
                stat: [1, 2] }

      @nodes.expects(:version).with('sw5', nil).returns(@versions)
      @nodes.expects(:get_diff).with('sw5', nil, 'C006', 'C001').returns(@diff)

      get '/node/version/diffs?node=sw5&group=&oid=C006&epoch=1738781340&num=3&oid2=C001'
      _(last_response.ok?).must_equal true
      body = last_response.body
      _(body).must_include('aria-label="Previous configuration lines"')
      _(body).must_include('aria-label="Selected configuration lines"')
      _(body).must_include('diff-line-removed')
      _(body).must_include('diff-line-added')
      _(body).must_include('changed line <mark class="diff-intraline-change">old</mark>')
      _(body).must_include('changed line <mark class="diff-intraline-change">new1</mark>')
      _(body).wont_include('diff --git a/sw5 b/sw5')
      _(body).wont_include('@@ -38,12 +38,12 @@')
      current_selector = body.split('id="currentRevision"', 2).last.split('</select>', 2).first
      previous_selector = body.split('id="previousRevision"', 2).last.split('</select>', 2).first
      _(current_selector).must_match(/<option(?=[^>]*\bselected(?:="selected")?(?:\s|>))(?=[^>]*value="C006")[^>]*>/)
      _(previous_selector).must_match(/<option(?=[^>]*\bselected(?:="selected")?(?:\s|>))(?=[^>]*value="C001")[^>]*>/)
      _(body).must_match(%r{diff-stat-mark added[^>]*>\+</span>\s*<strong>1</strong>\s*<span>lines added}m)
      _(body).must_match(%r{diff-stat-mark deleted[^>]*>−</span>\s*<strong>2</strong>\s*<span>lines removed}m)
      previous_pane = body.split('id="oldDiffPane"', 2).last.split('id="newDiffPane"', 2).first
      selected_pane = body.split('id="newDiffPane"', 2).last.split('id="unifiedDiff"', 2).first
      _(previous_pane).must_include('diff-line-removed diff-line-change')
      _(selected_pane).must_include('diff-line-added diff-line-change')
      unified_pane = body.split('id="unifiedDiff"', 2).last
      _(unified_pane).must_include('diff-line-removed diff-line-change')
      _(unified_pane).must_include('diff-line-added diff-line-change')
      _(previous_pane).must_include('changed line <mark class="diff-intraline-change">old</mark>')
      _(previous_pane).wont_include('new1</mark>')
      _(selected_pane).must_include('changed line <mark class="diff-intraline-change">new1</mark>')
      _(selected_pane).must_include('new2')
      _(selected_pane).wont_include('old</mark>')
      _(last_response.body).must_match(/<span class="time" epoch="1738781340">/)
    end

    it 'returns 200 when group param is absent (no NoMethodError)' do
      @versions = [
        { oid: "C006", time: Time.parse("2025-02-05 19:49:00 +0100") },
        { oid: "C003", time: Time.parse("2025-02-05 19:03:00 +0100") }
      ]
      @diff = { patch: "diff --git a/sw5 b/sw5\nsome diff\n", stat: [1, 1] }

      @nodes.expects(:version).with('sw5', nil).returns(@versions)
      @nodes.expects(:get_diff).with('sw5', nil, 'C006', nil).returns(@diff)

      get '/node/version/diffs?node=sw5&oid=C006&epoch=1738781340&num=2'
      _(last_response.ok?).must_equal true
    end

    it 'passes nil group to get_diff for ungrouped nodes' do
      @versions = [
        { oid: "C006", time: Time.parse("2025-02-05 19:49:00 +0100") },
        { oid: "C003", time: Time.parse("2025-02-05 19:03:00 +0100") }
      ]
      @diff = { patch: "diff --git a/sw5 b/sw5\nsome diff\n", stat: [1, 1] }

      # Explicitly assert nil is passed, not '' — empty string would resolve
      # to wrong git path in oxidized's yield_repo_and_path
      @nodes.expects(:version).with('sw5', nil).returns(@versions)
      @nodes.expects(:get_diff).with('sw5', nil, 'C006', nil).returns(@diff)

      get '/node/version/diffs?node=sw5&oid=C006&epoch=1738781340&num=2'
      _(last_response.ok?).must_equal true
    end

    it 'renders an explicit empty state for identical revisions' do
      versions = [
        { oid: 'C006', time: Time.parse('2025-02-05 19:49:00 +0100') },
        { oid: 'C003', time: Time.parse('2025-02-05 19:03:00 +0100') }
      ]
      @nodes.expects(:version).with('sw5', nil).returns(versions)
      @nodes.expects(:get_diff).with('sw5', nil, 'C006', 'C006').returns('no diffs')

      get '/node/version/diffs?node=sw5&oid=C006&epoch=1738781340&num=3&oid2=C006'

      _(last_response.ok?).must_equal true
      _(last_response.body).must_include('No configuration changes are available in this patch.')
      _(last_response.body).must_include('diff-empty-state')
      _(last_response.body).must_include('>—</strong>')
    end
  end
end
