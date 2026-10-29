require_relative '../spec_helper'

describe Oxidized::API::WebApp do
  include Rack::Test::Methods

  def app
    AuthenticatedWebTestGateway
  end

  describe '/' do
    it 'should redirect to /nodes' do
      AuthenticatedWebTestGateway.prepare
      get '/'

      _(last_response.redirect?).must_equal true
      _(last_response.location).must_equal 'http://example.org/nodes'
    end
  end
end
