require 'cfoundry'
require 'cf_light_api/model/orgs'

class CfClient

  def initialize(api, username, password)
    @@client = CFoundry::Client.get(api)
    @@client.login({:username => username, :password => password})
  end

  def orgs
    cf_rest()
  end

  def cf_rest
    Enumerator.new do |e|
      response = @@client.base.rest_client.request("GET", "/v2/organizations", options = {:accept => :json})[1][:body]
      data = Orgs.new(JSON.parse(response))

      while true do
        data.resources.each {|resource|
          e.yield resource
        }

        if data.next_url.nil?
          break
        else
          response = @@client.base.rest_client.request("GET", data.next_url, options = {:accept => :json})[1][:body]
          data = Orgs.new(JSON.parse(response))
        end
      end
    end
  end


  private :cf_rest

end