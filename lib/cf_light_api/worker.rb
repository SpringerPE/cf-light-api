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

  def formatted_instance_stats_for_app app
    instances = cf_rest("/v2/apps/#{app['metadata']['guid']}/stats")[0]
    raise "Unable to retrieve app instance stats: '#{instances['error_code']}'" if instances['error_code']
    instances.map{|key,value|value}
  end

  def cf_rest(path, method='GET')
    @logger.info "Making #{method} request for #{path}..."

    resources = []
    options = {:accept => :json}
    response = @cf_client.base.rest_client.request(method, path, options)[1][:body]

    begin
      response = JSON.parse(response)
    rescue Rufus::Scheduler::TimeoutError => e
      raise e
    rescue CFoundry, StandardError => e
      @logger.info "Error parsing JSON response from #{method} request for #{path}: #{e.message}"
      @logger.error e.backtrace
      @logger.error response
      raise "Error handling CF request #{method} #{path}"
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

  def send_org_quota_data_to_graphite(org_name, quota)
    graphite_base_key = "cf_orgs.#{ENV['CF_ENV_NAME']}.#{org_name}"
    @logger.info "  Exporting org quota statistics to Graphite, path '#{graphite_base_key}'"

    quota.keys.each do |key|
      @graphite.metrics "#{graphite_base_key}.quota.#{key}" => quota[key]
    end
  end

  def send_cf_light_api_update_time_to_graphite seconds
    graphite_key = "cf_light_api.#{ENV['CF_ENV_NAME']}.update_duration"
    @logger.info "Exporting CF Light API update time to Graphite, path '#{graphite_key}'=>'#{seconds.round}'"
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

  def format_routes_for_app app
    routes = cf_rest app['entity']['routes_url']
    routes.collect do |route|
      host   = route['entity']['host']
      path   = route['entity']['path']

      domain = ''
      begin
        domain = @domains.find{|a_domain| a_domain['metadata']['guid'] == route['entity']['domain_guid']}
        domain = domain['entity']['name']
      rescue Rufus::Scheduler::TimeoutError => e
        raise e
      rescue StandardError => e
        raise "Unable to determine domain for route #{route['metadata']['url']}"
      end

      "#{host}.#{domain}#{path}"
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

  def update_cf_data
    @cf_client = nil
    @graphite  = GraphiteAPI.new(graphite: "#{ENV['GRAPHITE_HOST']}:#{ENV['GRAPHITE_PORT']}") if ENV['GRAPHITE_HOST'] and ENV['GRAPHITE_PORT'] and ENV['CF_ENV_NAME']

    begin
      @lock_manager.lock("#{ENV['REDIS_KEY_PREFIX']}:lock", 5*60*1000) do |lock|
        if lock
          start_time = Time.now

          @logger.info "Updating data..."

          @cf_client = get_client() # Ensure we have a fresh auth token...

          @apps    = cf_rest('/v2/apps?results-per-page=100')
          @orgs    = cf_rest('/v2/organizations?results-per-page=100')
          @quotas  = cf_rest('/v2/quota_definitions?results-per-page=100')
          @spaces  = cf_rest('/v2/spaces?results-per-page=100')
          @stacks  = cf_rest('/v2/stacks?results-per-page=100')
          @domains = cf_rest('/v2/domains?results-per-page=100')
          cf_info  = cf_rest('/v2/info').first

          formatted_orgs = @orgs.map do |org|
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

          formatted_apps = Parallel.map(@apps, :in_threads => @update_threads) do |app|
            # TODO: This is a bit repetative, could maybe improve?
            space  = @spaces.find{|a_space| a_space['metadata']['guid'] == app['entity']['space_guid']}
            org    = @orgs.find{|an_org|     an_org['metadata']['guid'] == space['entity']['organization_guid']}
            stack  = @stacks.find{|a_stack| a_stack['metadata']['guid'] == app['entity']['stack_guid']}

            running = (app['entity']['state'] == "STARTED")

            base_data = {
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
              :stack         => stack['entity']['name'],
              :state         => app['entity']['state']
            }

            if ENV['EXPOSE_ENVIRONMENT_VARIABLES'] == 'true' then
              base_data[:environment_variables] = filtered_environment_variables( app['entity']['environment_json'] )
            end

            # Add additional data, such as instance usage statistics - but this is only possible if the instances are running.
            additional_data = {}

            begin
              instance_stats = []
              if running
                instance_stats = formatted_instance_stats_for_app(app)
                running_instances = instance_stats.select{|instance| instance['stats']['uris'] if instance['state'] == 'RUNNING'}
                raise "There are no running instances of this app." if running_instances.empty?

                if @graphite
                  send_instance_usage_data_to_graphite(instance_stats, org['entity']['name'], space['entity']['name'], app['entity']['name'])
                end
              end

              routes = format_routes_for_app(app)

              additional_data = {
               :running   => running,
               :instances => instance_stats,
               :routes    => routes,
               :error     => nil
              }

            rescue Rufus::Scheduler::TimeoutError => e
              raise e
            rescue StandardError => e
              # Most exceptions here will be caused by the app or one of the instances being in a non-standard state,
              # for example, trying to query an app which was present when the worker began updating, but was stopped
              # before we reached this section, so we just catch all exceptions, log the reason and move on.
              @logger.info "  #{org['entity']['name']} #{space['entity']['name']}: '#{app['entity']['name']}' error: #{e.message}"
              @logger.error e.backtrace
              additional_data = {
                :running   => 'error',
                :instances => [],
                :routes    => [],
                :error     => e.message
              }
            end

            base_data.merge additional_data
          end

          put_in_redis "#{ENV['REDIS_KEY_PREFIX']}:info", cf_info
          put_in_redis "#{ENV['REDIS_KEY_PREFIX']}:orgs", formatted_orgs
          put_in_redis "#{ENV['REDIS_KEY_PREFIX']}:apps", formatted_apps
          put_in_redis "#{ENV['REDIS_KEY_PREFIX']}:last_updated", {:last_updated => Time.now}

          elapsed_seconds = Time.now.to_f - start_time.to_f
          @logger.info "Update completed in #{format_duration(elapsed_seconds)}..."
          send_cf_light_api_update_time_to_graphite(elapsed_seconds) if @graphite

          @lock_manager.unlock(lock)
          @cf_client.logout
        else
          @logger.info "Update already running in another instance!"
        end
      end
    rescue Rufus::Scheduler::TimeoutError
      @logger.info 'Data update took too long and was aborted, waiting for the lock to expire before trying again...'
      send_cf_light_api_update_time_to_graphite(0) if @graphite
      @cf_client.logout
    end
  end

  if ENV['NEW_RELIC_LICENSE_KEY']
    add_transaction_tracer :update_cf_data, category: :task
    add_method_tracer :update_cf_data
  end

end

CFLightAPIWorker.new
