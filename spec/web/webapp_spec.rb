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
      _(result[:old_diff]).must_equal ['The text contains binary values - cannot display']
      _(result[:new_diff]).must_equal ['The text contains binary values - cannot display']
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
