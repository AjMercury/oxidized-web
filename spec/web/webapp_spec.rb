require_relative '../spec_helper'

# Test helper methods in Oxidized::API::WebApp

describe Oxidized::API::WebApp do
  include Rack::Test::Methods

  before do
    @webapp = Oxidized::API::WebApp.new
  end

  describe 'convert_to_utf8' do
    it 'cannot work with binary data' do
      # private method => we must use send
      result = @webapp.helpers.send(:convert_to_utf8, "\xff\x42 binary content\x00")
      _(result).must_equal 'The text contains binary values - cannot display'
    end
  end

  describe 'diff_view' do
    it 'cannot work with binary data' do
      # private method => we must use send
      result = @webapp.helpers.send(:diff_view, "\xff\x42 binary content\x00")
      _(result[:rows]).must_be_empty
      _(result[:message]).must_equal 'The text contains binary values - cannot display'
    end

    it 'parses line numbers, preserves whitespace, and aligns replacements and extra lines' do
      patch = "diff --git a/config b/config\n--- a/config\n+++ b/config\n" \
              "@@ -8,4 +10,5 @@\n context\n- description  old \n+ description  new \n+extra line\n \n last line\n"
      result = @webapp.helpers.send(:diff_view, patch)

      _(result[:message]).must_be_nil
      _(result[:rows]).must_equal [
        { kind: :context, old_number: 8, new_number: 10, old_text: 'context', new_text: 'context' },
        { kind: :modified, old_number: 9, new_number: 11, old_text: ' description  old ', new_text: ' description  new ' },
        { kind: :added, old_number: nil, new_number: 12, old_text: nil, new_text: 'extra line' },
        { kind: :context, old_number: 10, new_number: 13, old_text: '', new_text: '' },
        { kind: :context, old_number: 11, new_number: 14, old_text: 'last line', new_text: 'last line' }
      ]
    end

    it 'marks only the changed Unicode character range in a replacement' do
      result = @webapp.helpers.send(:diff_intraline, 'Port café-west', 'Port café-east')

      _(result[:old]).must_equal ['Port café-', 'we', 'st']
      _(result[:new]).must_equal ['Port café-', 'ea', 'st']
    end

    it 'highlights a changed multibyte character in intraline comparisons' do
      result = @webapp.helpers.send(:diff_intraline, 'Port café-west', 'Port cafe-west')

      _(result[:old]).must_equal ['Port caf', 'é', '-west']
      _(result[:new]).must_equal ['Port caf', 'e', '-west']
    end

    it 'ignores preamble-only and malformed hunk headers' do
      result = @webapp.helpers.send(:diff_view, "diff --git a/config b/config\n@@ -x +y @@\n+not parsed\n")

      _(result[:rows]).must_be_empty
      _(result[:message]).must_equal 'No configuration changes are available in this patch.'
    end

    it 'handles pure additions, pure deletions, and empty patches with exact line numbers' do
      additions = @webapp.helpers.send(:diff_view, "@@ -3,0 +4,2 @@\n+  add one\n+\tadd two\n")
      _(additions[:rows]).must_equal [
        { kind: :added, old_number: nil, new_number: 4, old_text: nil, new_text: '  add one' },
        { kind: :added, old_number: nil, new_number: 5, old_text: nil, new_text: "\tadd two" }
      ]

      deletions = @webapp.helpers.send(:diff_view, "@@ -7,2 +8,0 @@\n- remove one\n-\tremove two\n")
      _(deletions[:rows]).must_equal [
        { kind: :removed, old_number: 7, new_number: nil, old_text: ' remove one', new_text: nil },
        { kind: :removed, old_number: 8, new_number: nil, old_text: "\tremove two", new_text: nil }
      ]

      empty = @webapp.helpers.send(:diff_view, '')
      _(empty[:rows]).must_be_empty
      _(empty[:message]).must_equal 'No configuration changes are available in this patch.'
    end

    it 'keeps large whitespace-heavy network configuration hunks aligned' do
      context_lines = 2_000.times.map { |index| "  interface ethernet#{index}\n" }.join
      patch = "@@ -1,2001 +1,2001 @@\n#{context_lines}-  description old\n+  description new\n"
      result = @webapp.helpers.send(:diff_view, patch)

      _(result[:rows].length).must_equal 2_001
      _(result[:rows].first).must_equal(
        { kind: :context, old_number: 1, new_number: 1,
          old_text: ' interface ethernet0', new_text: ' interface ethernet0' }
      )
      _(result[:rows].last).must_equal(
        { kind: :modified, old_number: 2_001, new_number: 2_001,
          old_text: '  description old', new_text: '  description new' }
      )
    end
  end

  describe 'backup timestamps' do
    it 'treats missing, zero, and pre-epoch values as unavailable' do
      [nil, '', '0', 0, Time.at(0), Time.at(-1), '1970-01-01T00:00:00Z'].each do |value|
        _(@webapp.helpers.send(:timestamp_time, value)).must_be_nil
      end
    end

    it 'preserves an authoritative positive historical timestamp' do
      timestamp = Time.utc(2026, 10, 29, 10, 15, 30)
      _(@webapp.helpers.send(:timestamp_time, timestamp)).must_equal timestamp
      _(@webapp.helpers.send(:timestamp_time, timestamp.to_i.to_s)).must_equal timestamp
    end
  end
end
