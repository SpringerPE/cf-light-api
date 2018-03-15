require 'cfoundry'
require 'json'
require 'rufus-scheduler'
require 'redlock'
require 'logger'
require 'graphite-api'
require 'date'
require 'parallel'

class CFLightAPIWorker
  if ENV['NEW_RELIC_LICENSE_KEY']
    require 'newrelic_rpm'
    include NewRelic::Agent::Instrumentation::ControllerInstrumentation
    include NewRelic::Agent::MethodTracer
  end

  ENVIRONMENT_VARIABLES_WHITELIST = (ENV['ENVIRONMENT_VARIABLES_WHITELIST'] || '').split(',').collect(&:strip)

  def initialize
    @logger = Logger.new(STDOUT)

    if ENV['DEBUG']
      @logger.level = Logger::DEBUG
    else
      @logger.level = Logger::INFO
    end

    @logger.formatter = proc do |severity, datetime, progname, msg|
       "#{datetime} [cf_light_api:worker]: #{msg}\n"
    end

    ['CF_API', 'CF_USER', 'CF_PASSWORD'].each do |env|
      unless ENV[env]
        @logger.info "Error: please set the '#{env}' environment variable."
        exit 1
      end
    end

    # If either of the Graphite settings are set, verify that they are both set, or exit with an error. CF_ENV_NAME is used
    # to prefix the Graphite key, to allow filtering by environment if you run more than one.
    if ENV['GRAPHITE_HOST'] or ENV['GRAPHITE_PORT']
      ['GRAPHITE_HOST', 'GRAPHITE_PORT', 'CF_ENV_NAME'].each do |env|
        unless ENV[env]
          @logger.info "Error: please also set the '#{env}' environment variable to enable exporting to Graphite."
          exit 1
        end
      end
    end

    update_interval = (ENV['UPDATE_INTERVAL'] || '5m').to_s # If you change the default '5m' here, also remember to change the default age validity in sinatra/cf_light_api.rb:31
    update_timeout  = (ENV['UPDATE_TIMEOUT']  || '5m').to_s

    @update_threads  = (ENV['UPDATE_THREADS'] || 1).to_i

    @lock_manager = Redlock::Client.new([ENV['REDIS_URI']])
    @scheduler    = Rufus::Scheduler.new

    @logger.info "Update interval: '#{update_interval}'"
    @logger.info "Update timeout:  '#{update_timeout}'"
    @logger.info "Update threads:  '#{@update_threads}'"

    if ENV['GRAPHITE_HOST'] and ENV['GRAPHITE_PORT']
      @logger.info "Graphite server: #{ENV['GRAPHITE_HOST']}:#{ENV['GRAPHITE_PORT']}"
    else
      @logger.info 'Graphite server: Disabled'
    end

    @scheduler.every update_interval, :first_in => '5s', :overlap => false, :timeout => update_timeout do
      update_cf_data
    end
  end

  def cf_rest(path, method='GET')
    @logger.debug "Making #{method} request for #{path}..."

    resources = []
    options   = {:accept => :json}
    response  = @cf_client.base.rest_client.request(method, path, options)[1][:body]

    begin
      response = JSON.parse(response)
      if response['error_code']
        raise CFResponseError.new("Code #{response['code']}, #{response['error_code']} - #{response['description']}")
      end

    rescue Rufus::Scheduler::TimeoutError => e
      raise e
    rescue JSON::ParserError => e
      @logger.error "Error parsing JSON response from #{method} #{path}: #{e.message}"
      @logger.trace e.backtrace
      @logger.trace response
      raise e
    rescue CFoundry => e
      @logger.error "CFoundry error making #{method} #{path}: #{e.message}"
      @logger.trace e.backtrace
      @logger.trace response
      raise e
    rescue CFResponseError => e
      @logger.error "CF API returned a response with an error document for #{method} #{path}: #{e.message}"
      @logger.trace e.backtrace
      @logger.trace response
      raise e
    rescue StandardError => e
      @logger.error "General error making #{method} #{path}: #{e.message}"
      @logger.trace e.backtrace
      @logger.trace response
      raise e
    end

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
    sanitised_app_name = app_name.gsub ".", "_" # Some apps have dots in the app name which breaks the Graphite key path

    instance_stats.each_with_index do |instance_data, index|
      graphite_base_key = "cf_apps.#{ENV['CF_ENV_NAME']}.#{org}.#{space}.#{sanitised_app_name}.#{index}"
      @logger.debug "  Exporting app instance \##{index} usage statistics to Graphite, path '#{graphite_base_key}'"

      # Quota data
      ['mem_quota', 'disk_quota'].each do |key|
        @logger.trace "#{graphite_base_key}.#{key} => #{instance_data['stats'][key]}"
        @graphite.metrics "#{graphite_base_key}.#{key}" => instance_data['stats'][key]
      end

      # Usage data
      ['mem', 'disk', 'cpu'].each do |key|
        @logger.trace "#{graphite_base_key}.#{key} => #{instance_data['stats']['usage'][key]}"
        @graphite.metrics "#{graphite_base_key}.#{key}" => instance_data['stats']['usage'][key]
      end
    end
  end

  def send_org_quota_data_to_graphite(org_name, quota)
    graphite_base_key = "cf_orgs.#{ENV['CF_ENV_NAME']}.#{org_name}"
    @logger.debug "  Exporting org quota statistics to Graphite, path '#{graphite_base_key}'"

    quota.keys.each do |key|
      @logger.trace "#{graphite_base_key}.quota.#{key} => #{quota[key]}"
      @graphite.metrics "#{graphite_base_key}.quota.#{key}" => quota[key]
    end
  end

  def send_cf_light_api_update_time_to_graphite seconds
    graphite_key = "cf_light_api.#{ENV['CF_ENV_NAME']}.update_duration"
    @logger.info "Exporting CF Light API update time to Graphite, path #{graphite_key} => #{seconds.round}"
    @graphite.metrics "#{graphite_key}" => seconds.round
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

  def update_domains
    @domains = cf_rest('/v2/domains?results-per-page=100')
  end

  def get_buildpacks_by_guid
    buildpacks = cf_rest('/v2/buildpacks?results-per-page=100')
    buildpacks_by_guid = buildpacks.map { |buildpack| [buildpack['metadata']['guid'], buildpack] }.to_h
  end

  def find_domain_for_route route
    return @domains.find{|a_domain| a_domain['metadata']['guid'] == route['entity']['domain_guid']}
  end

  def format_routes_for_app app
    # The app object passed in here should contain a "routes" attribute, fetched as part of the original request to CF (with inline-relation gathering enabled)
    # and it will look something like this:
    # "routes"=>
    # [{"metadata"=>{"guid"=>"afea5690-fb93-451a-9610-2d524d36e35f", "url"=>"/v2/routes/afea5690-fb93-451a-9610-2d524d36e35f", "created_at"=>"2015-03-11T12:20:22Z", "updated_at"=>"2015-03-11T12:20:22Z"},
    #   "entity"=>
    #    {"host"=>"hostname_here",
    #     "path"=>"",
    #     "domain_guid"=>"f13e6864-537e-41bb-b46c-f3810dbf7c84",
    #     "space_guid"=>"c0af44b8-8b51-4db5-927e-ccad2e6dab54",
    #     "service_instance_guid"=>nil,
    #     "port"=>nil,
    #     "domain_url"=>"/v2/shared_domains/f13e6864-537e-41bb-b46c-f3810dbf7c84",
    #     "space_url"=>"/v2/spaces/c0af44b8-8b51-4db5-927e-ccad2e6dab54",
    #     "apps_url"=>"/v2/routes/afea5690-fb93-451a-9610-2d524d36e35f/apps",
    #     "route_mappings_url"=>"/v2/routes/afea5690-fb93-451a-9610-2d524d36e35f/route_mappings"}},
    # If we don't receive that child attribute, (perhaps the app was being staged or didn't have any routes yet) we make another request to CF to try
    # and fetch them before giving up and just returning an empty array.

    routes = []
    if app['entity']['routes'] == nil
      # We have no routes data inlined with the app entity, so let's try to retrieve them directly from CF
      routes = cf_rest(app['entity']['routes_url'])
    else
      # Routes were already retrieved as an inline-relation, so just use those...
      routes = app['entity']['routes']
    end

    routes.collect do |route|
      host   = route['entity']['host']
      path   = route['entity']['path']

      domain = find_domain_for_route(route)
      if domain == nil
        # The domain doesn't exist, this could be due to a race condition, so let's update the list and try again
        update_domains()
        domain = find_domain_for_route(route)
        if domain == nil
          # If we can't determine the domain associated with this route, raise an error as we can't guarantee the state is correct here,
          # it shouldn't be possible to get a route back from CF with a domain GUID that doesn't exist, as that route would be invalid.
          raise "Unable to find domain #{route['entity']['domain_guid']} for route #{route['metadata']['guid']}."
        end
      end
      "#{host}.#{domain['entity']['name']}#{path}"
    end
  end

  def filtered_environment_variables env_vars
    if ENVIRONMENT_VARIABLES_WHITELIST.any?
      return ENVIRONMENT_VARIABLES_WHITELIST.inject({}) do |filtered, key|
        filtered[key] = env_vars[key] if env_vars[key]
        filtered
      end

    else
      return env_vars
    end
  end

  def format_orgs orgs
    return orgs.map do |org|
      quota = @quotas.find{|a_quota| a_quota['metadata']['guid'] == org['entity']['quota_definition_guid']}

      quota = {
        :total_services => quota['entity']['total_services'],
        :total_routes   => quota['entity']['total_routes'],
        :memory_limit   => quota['entity']['memory_limit'] * 1024 * 1024
      }

      send_org_quota_data_to_graphite(org['entity']['name'], quota) if @graphite

      {
        :guid => org['metadata']['guid'],
        :name  => org['entity']['name'],
        :quota => quota
      }
    end
  end

  def get_v1_base_data app
    # Format the app data in the expected format for the /v1/apps endpoint, to remain compatible.

    # Find the org for this app, using the org GUID from the space. Relationship: Apps belong to spaces, and spaces belong to orgs.
    space = @spaces.find{|a_space| a_space['metadata']['guid'] == app['entity']['space_guid']}
    org = @orgs.find{|an_org| an_org['metadata']['guid'] == space['entity']['organization_guid']}

    {
      :buildpack     => app['entity']['buildpack'],
      :data_from     => Time.now.to_i,
      :diego         => app['entity']['diego'],
      :docker        => app['entity']['docker_image'] ? true : false,
      :docker_image  => app['entity']['docker_image'],
      :guid          => app['metadata']['guid'],
      :last_uploaded => app['metadata']['updated_at'] ? DateTime.parse(app['metadata']['updated_at']).strftime('%Y-%m-%d %T %z') : nil,
      :name          => app['entity']['name'],
      :org           => org['entity']['name'],
      :space         => space['entity']['name'],
      :stack         => app['entity']['stack']['entity']['name'],
      :state         => app['entity']['state'],
      :instances     => [],
      :routes        => []
    }
  end

  def update_cf_data
    @cf_client = nil
    @graphite  = GraphiteAPI.new(graphite: "#{ENV['GRAPHITE_HOST']}:#{ENV['GRAPHITE_PORT']}") if ENV['GRAPHITE_HOST'] and ENV['GRAPHITE_PORT'] and ENV['CF_ENV_NAME']

    begin
      @lock_manager.lock("#{ENV['REDIS_KEY_PREFIX']}:lock", 5*60*1000) do |lock|
        if lock
          start_time = Time.now
          @logger.info "Updating data..."
          @cf_client = get_client() # Ensure we have a fresh auth token...

          @cf_info  = cf_rest('/v2/info').first

          @apps = cf_rest('/v2/apps?results-per-page=100&inline-relations-depth=1&include-relations=routes,stack')
          @spaces  = cf_rest('/v2/spaces?results-per-page=100')
          @buildpacks = get_buildpacks_by_guid() # Sets @buildpacks to a map of buildpack resources indexed by guid

          update_domains() # Sets @domain by hitting the CF API

          # Orgs
          @orgs          = cf_rest('/v2/organizations?results-per-page=100')
          @quotas        = cf_rest('/v2/quota_definitions?results-per-page=100')
          formatted_orgs = format_orgs @orgs

          v1_data = []
          v2_data = []

          Parallel.each(@apps, :in_threads => @update_threads) do |app|
            begin
              # Formats the base data compatible with the v1 endpoint
              v1_document = get_v1_base_data(app)

              # New format base data for the v2 endpoint
              v2_document                          = app['entity'].dup
              v2_document['environment_json']      = {} # The environment JSON will have been duplicated from the app entity, so we need to blank it here, as it will be re-populated later if EXPOSE_ENVIRONMENT_VARIABLES is true.
              v2_document['created_at']            = app['metadata']['created_at']
              v2_document['updated_at']            = app['metadata']['updated_at']
              v2_document['guid']                  = app['metadata']['guid']
              v2_document['instances']             = []
              v2_document['routes']                = []
              v2_document['meta']                  = { 'error' => false }

              # Add buildpack_name as a top level string attribute and looks it up using its guid when the buildpack field is null
              buildpack_name = app['entity']['buildpack']
              buildpack_guid = app['entity']['detected_buildpack_guid']

              v2_document['buildpack_name'] = buildpack_name

              if buildpack_name.nil? or buildpack_name.empty?
                  v2_document['buildpack_name'] = @buildpacks[buildpack_guid]['entity']['name']
              end

              # Add space, stack and org names as a top level string attribute for ease of use:
              v2_document['stack'] = app['entity']['stack']['entity']['name']

              # Get the org name from the app's space - relationship: an app belongs to a space, and a space belongs to an org.
              space = @spaces.find{|a_space| a_space['metadata']['guid'] == app['entity']['space_guid']}
              org = @orgs.find{|an_org| an_org['metadata']['guid'] == space['entity']['organization_guid']}

              v2_document['space'] = space['entity']['name']
              v1_document['org'] = org['entity']['name']
              v2_document['org'] = org['entity']['name']

              # Gather and filter environment variable JSON if the feature is enabled:
              if ENV['EXPOSE_ENVIRONMENT_VARIABLES'] == 'true' then
                env_vars = filtered_environment_variables( app['entity']['environment_json'] )
                v1_document['environment_variables'] = env_vars
                v2_document['environment_json']      = env_vars
              end

              routes = format_routes_for_app(app)
              v1_document['routes'] = routes
              v2_document['routes'] = routes

              # Try to gather app instance stats, unless the app is stopped...
              unless app['entity']['state'] == 'STOPPED'
                response = cf_rest("/v2/apps/#{app['metadata']['guid']}/stats")
                instances = response.first.map{|key,value|value}
                v1_document['instances'] = instances
                v2_document['instances'] = instances
              end

              # We consider an app to be "running" if there is at least one app instance available with a state of "RUNNING"
              running = false
              running_instances = []
              if v2_document['instances'].any?
                running_instances = v2_document['instances'].select{|instance| instance['state'] == 'RUNNING'}
                running = true if running_instances.any?
              end
              v1_document['running'] = running
              v2_document['running'] = running

              if @graphite
                if running_instances.any?
                  send_instance_usage_data_to_graphite(running_instances, v2_document['org'], v2_document['space'], v2_document['name'])
                end
              end

            rescue Rufus::Scheduler::TimeoutError => e
              raise e
            rescue CFoundry, CFResponseError, StandardError => e
              v1_document['running']           = "error"
              v1_document['error']             = "#{e.message}"

              v2_document['meta']              = {}
              v2_document['meta']['error']     = true
              v2_document['meta']['type']      = e.class
              v2_document['meta']['message']   = e.message
              v2_document['meta']['backtrace'] = e.backtrace
            end

            v1_data << v1_document
            v2_data << v2_document
          end

          # Sanity check - do we have the expected quantity of data? This shouldn't happen as the `parallel` gem should handle
          # sharing and modifying variables for us when using threads.
          if @apps.count != v1_data.count or @apps.count != v2_data.count
            raise "V1 and V2 app counts don't match after processing!"
          end

          put_in_redis "#{ENV['REDIS_KEY_PREFIX']}:info", @cf_info
          put_in_redis "#{ENV['REDIS_KEY_PREFIX']}:orgs", formatted_orgs
          put_in_redis "#{ENV['REDIS_KEY_PREFIX']}:apps", v1_data
          put_in_redis "#{ENV['REDIS_KEY_PREFIX']}:apps:v2", v2_data

          put_in_redis "#{ENV['REDIS_KEY_PREFIX']}:last_updated", {:last_updated => Time.now}

          elapsed_seconds = Time.now.to_f - start_time.to_f

          send_cf_light_api_update_time_to_graphite(elapsed_seconds) if @graphite
          @logger.info "Update completed in #{format_duration(elapsed_seconds)}..."

          @lock_manager.unlock(lock)
          @cf_client.logout
        else
          @logger.info "Update already running in another instance!"
        end
      end
    rescue Rufus::Scheduler::TimeoutError
      Parallel::Kill
      @cf_client.logout
      @logger.info 'Data update took too long and was aborted, waiting for the lock to expire before trying again...'
      send_cf_light_api_update_time_to_graphite(0) if @graphite
    rescue StandardError => e
      @logger.info "Unable to complete update due to #{e.class}: #{e.message}"
      @logger.error e.backtrace
    end
  end

  if ENV['NEW_RELIC_LICENSE_KEY']
    add_transaction_tracer :update_cf_data, category: :task
    add_method_tracer :update_cf_data
  end

end

CFLightAPIWorker.new
