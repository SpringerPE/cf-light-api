require 'cfoundry'
require 'json'
require 'rufus-scheduler'
require 'parallel'
require 'redlock'
require 'logger'
require 'graphite-api'
require 'date'

@logger = Logger.new(STDOUT)
@logger.formatter = proc do |severity, datetime, progname, msg|
   "#{datetime} [cf_light_api:worker]: #{msg}\n"
end

['CF_API', 'CF_USER', 'CF_PASSWORD'].each do |env|
  unless ENV[env]
    @logger.info "Error: please set the '#{env}' environment variable."
    exit 1
  end
end

PARALLEL_MAPS   = (ENV['PARALLEL_MAPS']   || 4   ).to_i
UPDATE_INTERVAL = (ENV['UPDATE_INTERVAL'] || '5m').to_s # If you change the default '5m' here, also remember to change the default age validity in sinatra/cf_light_api.rb:31
UPDATE_TIMEOUT  = (ENV['UPDATE_TIMEOUT']  || '5m').to_s

lock_manager = Redlock::Client.new([ENV['REDIS_URI']])
scheduler    = Rufus::Scheduler.new

@logger.info "Parallel maps:   '#{PARALLEL_MAPS}'"
@logger.info "Update interval: '#{UPDATE_INTERVAL}'"
@logger.info "Update timeout:  '#{UPDATE_TIMEOUT}'"
@logger.info "Graphite server: #{ENV['GRAPHITE']}" if ENV['GRAPHITE']

#@domains = {}
# @domains   = cf_rest('/v2/domains?results-per-page=100') # We're retrieving this from the app instance 'uris' key instead.
# @routes    = cf_rest('/v2/routes?results-per-page=100')

# def formatted_routes_for_app app
#   routes = cf_rest(app['entity']['routes_url'])

#   routes.collect do |route|
#     domain = @domains.find{|a_domain| a_domain['metadata']['guid'] ==  route['entity']['domain_guid']}['entity']['name']
#     # Suffix the hostname with a period for concatenation, unless it's blank (which can happen for apex routes).
#     host = route['entity']['host'] != '' ? "#{route['entity']['host']}." : ''
#     path = route['entity']['path']
#     "#{host}#{domain}#{path}"
#   end
# end

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

scheduler.every UPDATE_INTERVAL, :first_in => '5s', :overlap => false, :timeout => UPDATE_TIMEOUT do
  @cf_client = nil
  # graphite  = GraphiteAPI.new(graphite: ENV['GRAPHITE']) if ENV['GRAPHITE']

  begin
    lock_manager.lock("#{ENV['REDIS_KEY_PREFIX']}:lock", 5*60*1000) do |lock|
      if lock
        start_time = Time.now

        @logger.info "Updating data..."

        @cf_client = get_client() # Ensure we have a fresh auth token...

        @apps      = cf_rest('/v2/apps?results-per-page=100')
        @orgs      = cf_rest('/v2/organizations?results-per-page=100')
        @quotas    = cf_rest('/v2/quota_definitions?results-per-page=100')
        @spaces    = cf_rest('/v2/spaces?results-per-page=100')
        @stacks    = cf_rest('/v2/stacks?results-per-page=100')

        # org_data = get_org_data(@cf_client)
        # app_data = get_app_data(@cf_client, graphite)

        formatted_orgs = @orgs.map do |org|
          quota = @quotas.find{|a_quota| a_quota['metadata']['guid'] == org['entity']['quota_definition_guid']}

          {
            :guid => org['metadata']['guid'],
            :name  => org['entity']['name'],
            :quota => {
              :name           => quota['entity']['name'],
              :total_services => quota['entity']['total_services'],
              :total_routes   => quota['entity']['total_routes'],
              :memory_limit   => quota['entity']['memory_limit'] * 1024 * 1024
            }
          }
        end

        formatted_apps = @apps.map do |app|
          # TODO: This is a bit repetative, could improve.
          space = @spaces.find{|a_space| a_space['metadata']['guid'] == app['entity']['space_guid']}
          org   = @orgs.find{|an_org|     an_org['metadata']['guid'] == space['entity']['organization_guid']}
          stack = @stacks.find{|a_stack| a_stack['metadata']['guid'] == app['entity']['stack_guid']}

          running = (app['entity']['state'] == "STARTED")

          base_data = {
            :guid          => app['metadata']['guid'],
            :name          => app['entity']['name'],
            :org           => org['entity']['name'],
            :space         => space['entity']['name'],
            :stack         => stack['entity']['name'],
            :buildpack     => app['entity']['buildpack'],
            # This requires a call to /v2/apps/[guid]/routes for each app, or we can just use the 'uris' key from /v2/apps/[guid]/stats
            # which we have to call anyway, to get app instance usage stats..
            # :routes        => running ? formatted_routes_for_app(app) : [],
            :data_from     => Time.now.to_i,
            :last_uploaded => app['metadata']['updated_at'] ? DateTime.parse(app['metadata']['updated_at']).strftime('%Y-%m-%d %T %z') : nil
          }

          additional_data = {}
          begin
            instance_stats = []
            routes         = []
            if running
              instance_stats = formatted_instance_stats_for_app(app)
              # Finds the first running app instance that has a set of routes, in case there are stopped/crashed app instances that don't have any.
              running_instances = instance_stats.select{|instance| instance['stats']['uris'] if instance['state'] == 'RUNNING'}
              raise "Unable to retrieve app routes - no app instances are running." if running_instances.empty?
              routes = running_instances.first['stats']['uris']
            end

            additional_data = {
             :running   => running,
             :instances => instance_stats,
             :routes    => routes,
             :error     => nil
            }
          rescue => e
            @logger.info "  #{org['entity']['name']} #{space['entity']['name']}: '#{app['entity']['name']}' error: #{e.message}"
            additional_data = {
              :running   => 'error',
              :instances => [],
              :routes    => [],
              :error     => e.message
            }
          end

          base_data.merge additional_data
        end

        put_in_redis "#{ENV['REDIS_KEY_PREFIX']}:orgs", formatted_orgs
        put_in_redis "#{ENV['REDIS_KEY_PREFIX']}:apps", formatted_apps
        put_in_redis "#{ENV['REDIS_KEY_PREFIX']}:last_updated", {:last_updated => Time.now}

        @logger.info "Update completed in #{format_duration(Time.now.to_f - start_time.to_f)}..."
        lock_manager.unlock(lock)
        @cf_client.logout
      else
        @logger.info "Update already running in another instance!"
      end
    end
  rescue Rufus::Scheduler::TimeoutError
    @logger.info 'Data update took too long and was aborted, waiting for the lock to expire before trying again...'
    @cf_client.logout
  end
end

def get_client(cf_api=ENV['CF_API'], cf_user=ENV['CF_USER'], cf_password=ENV['CF_PASSWORD'])
  client = CFoundry::Client.get(cf_api)
  client.login({:username => cf_user, :password => cf_password})
  client
end

# def send_data_to_graphite(data, graphite)
#   org   = data[:org]
#   space = data[:space]
#   name  = data[:name].sub ".", "_" # Some apps have dots in the app name

#   data[:instances].each_with_index do |instance_data, index|
#     graphite_base_key = "cf_apps.#{org}.#{space}.#{name}.#{index}"

#     # Quota data
#     [:mem_quota, :disk_quota].each do |key|
#       graphite.metrics "#{graphite_base_key}.#{key}" => instance_data[:stats][key]
#     end

#     # Usage data
#     [:mem, :disk, :cpu].each do |key|
#       graphite.metrics "#{graphite_base_key}.#{key}" => instance_data[:stats][:usage][key]
#     end
#   end
# end

# def get_app_data(cf_client, graphite)
#   Parallel.map(cf_client.organizations, :in_threads=> PARALLEL_MAPS) do |org|
#     org_name = org.name
#     Parallel.map(org.spaces, :in_threads => PARALLEL_MAPS) do |space|
#       space_name = space.name
#       @logger.info "Getting app data for apps in #{org_name}:#{space_name}..."
#       Parallel.map(space.apps, :in_threads=> PARALLEL_MAPS) do |app|
#         begin
#           # It's possible for an app to have been terminated before this stage is reached.
#           formatted_app_data = format_app_data(app, org_name, space_name)
#           if graphite
#             send_data_to_graphite(formatted_app_data, graphite)
#           end
#           formatted_app_data
#         rescue CFoundry::AppNotFound
#           next
#         end
#       end
#     end
#   end.flatten.compact
# end

# def get_org_data(cf_client)
#   Parallel.map( cf_client.organizations, :in_threads=> PARALLEL_MAPS) do |org|
#     @logger.info "Getting org data for #{org.name}..."
#     # The CFoundry client returns memory_limit in MB, so we need to normalise to bytes to match the Apps.
#     {
#       :guid => org.guid,
#       :name => org.name,
#       :quota => {
#         :total_services => org.quota_definition.total_services,
#         :memory_limit   => org.quota_definition.memory_limit * 1024 * 1024
#       }
#     }
#   end.flatten.compact
# end

# def format_app_data(app, org_name, space_name)

#   last_uploaded = (app.manifest[:entity][:package_updated_at] ||= nil)

#   base_data = {
#     :guid          => app.guid,
#     :name          => app.name,
#     :org           => org_name,
#     :space         => space_name,
#     :stack         => app.stack.name,
#     :buildpack     => app.buildpack,
#     :routes        => app.running? ? routes_for_app(app) : [],
#     :data_from     => Time.now.to_i,
#     :last_uploaded => last_uploaded ? DateTime.parse(last_uploaded).strftime('%Y-%m-%d %T %z') : nil
#   }

#   additional_data = {}
#   begin
#     additional_data = {
#      :running   => app.running?,
#      :instances => app.running? ? app.stats.map{|key, value| value} : [],
#      :error     => nil
#     }
#   rescue => e
#     @logger.info "  #{org_name} #{space_name}: '#{app.name}'' error: #{e.message}"
#     additional_data = {
#       :running   => 'error',
#       :instances => [],
#       :error     => e.message
#     }
#   end

#   base_data.merge additional_data
# end

# def routes_for_app app
#   guids   = space.apps.first.routes.collect{|route| route.guid}
#   guids.collect{|guid| @domains.select{|domain| domain[:guid] == guid}}
#   @domains.collect
# end

def put_in_redis(key, data)
  REDIS.set key, data.to_json
end

def format_duration(elapsed_seconds)
  seconds = elapsed_seconds % 60
  minutes = (elapsed_seconds / 60) % 60
  hours   = elapsed_seconds / (60 * 60)
  format("%02d hrs, %02d mins, %02d secs", hours, minutes, seconds)
end
