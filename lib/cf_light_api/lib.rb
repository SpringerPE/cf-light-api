def formatted_instance_stats_for_app app
  instances = cf_rest("/v2/apps/#{app['metadata']['guid']}/stats")[0]
  raise "Unable to retrieve app instance stats: '#{instances['error_code']}'" if instances['error_code']
  instances.map{|key,value|value}
end

def cf_rest(path, method='GET')
  @logger.info "Making #{method} request for #{path}..."

  resources = []
  response = JSON.parse(@cf_client.base.rest_client.request(method, path)[1][:body])
  
  # Some endpoints return a 'resources' array, others are flat, depending on the path.
  if response['resources'] 
    resources << response['resources']
  else
    resources << response
  end

  # Handle the pagination by recursing over myself until we get a response which doesn't contain a 'next_url'
  # at which point all the resources are returned up the stack and flattened.
  resources << cf_rest(response['next_url'], method) unless response['next_url'] == nil
  resources.flatten
end

def get_client(cf_api=ENV['CF_API'], cf_user=ENV['CF_USER'], cf_password=ENV['CF_PASSWORD'])
  client = CFoundry::Client.get(cf_api)
  client.login({:username => cf_user, :password => cf_password})
  client
end

def send_instance_usage_data_to_graphite(instance_stats, org, space, app_name)
  app_name.gsub! ".", "_" # Some apps have dots in the app name

  instance_stats.each_with_index do |instance_data, index|
    graphite_base_key = "cf_apps.#{org}.#{space}.#{app_name}.#{index}"
    @logger.info "  Exporting app instance \##{index} usage statistics to Graphite, path '#{graphite_base_key}'"

    # Quota data
    ['mem_quota', 'disk_quota'].each do |key|
      @graphite.metrics "#{graphite_base_key}.#{key}" => instance_data['stats'][key]
    end

    # Usage data
    ['mem', 'disk', 'cpu'].each do |key|
      @graphite.metrics "#{graphite_base_key}.#{key}" => instance_data['stats']['usage'][key]
    end
  end
end

def put_in_redis(key, data)
  REDIS.set key, data.to_json
end

def format_duration(elapsed_seconds)
  seconds = elapsed_seconds % 60
  minutes = (elapsed_seconds / 60) % 60
  hours   = elapsed_seconds / (60 * 60)
  format("%02d hrs, %02d mins, %02d secs", hours, minutes, seconds)
end

def format_routes_for_app app
  routes = cf_rest app['entity']['routes_url']
  routes.collect do |route|
    host   = route['entity']['host']
    path   = route['entity']['path']

    domain = @domains.find{|a_domain| a_domain['metadata']['guid'] == route['entity']['domain_guid']}
    domain = domain['entity']['name']

    "#{host}.#{domain}#{path}"
  end
end
