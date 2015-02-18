require 'clockwork'
require 'cfoundry'
require 'redis'
require 'json'

include Clockwork

def get_client(cf_api=ENV['cf_api'], cf_user=ENV['cf_user'], cf_password=ENV['cf_password'])
  client = CFoundry::Client.get(cf_api)
  client.login({:username => cf_user, :password => cf_password})
  client
end

def format_app_data(app, org_name, space_name)
  {
    :org => org_name,
    :space => space_name,
    :name => app.name,
    :routes => app.routes.map {|route| route.name},
    :data_from => Time.now.to_i,
    :running => app.running?,
    :stats => app.running? ? app.stats : {}
  }
end

def put_in_redis(redis_uri=ENV['redis_uri'], redis_key=ENV['redis_key'], data)
  redis = Redis.new(:url => redis_uri)
  redis.set redis_key, data.to_json
end

handler do |job|
  cf_client = get_client()

  data = []
  cf_client.organizations.each do |org|
    org_name = org.name
    org.spaces.each do |space|
      space_name = space.name
      space.apps.each do |app|
        data << format_app_data(app, org_name, space_name)
      end
    end
  end
  puts "Putting data #{data} into redis"
  put_in_redis(data)
end


# Define the schedule
every(5.minutes, 'put cf data in redis')
