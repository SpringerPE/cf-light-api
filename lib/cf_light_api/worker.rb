require 'cfoundry'
require 'json'
require 'rufus-scheduler'
require 'redlock'
require 'logger'
require 'graphite-api'
require 'date'

require_relative 'lib.rb'

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

# If either of the Graphite settings are set, verify that they are both set, or exit with an error.
if ENV['GRAPHITE_HOST'] or ENV['GRAPHITE_PORT']
  ['GRAPHITE_HOST', 'GRAPHITE_PORT'].each do |env|
    unless ENV[env]
      @logger.info "Error: please set the '#{env}' environment variable to enable exporting to Graphite."
      exit 1
    end
  end
end

UPDATE_INTERVAL = (ENV['UPDATE_INTERVAL'] || '5m').to_s # If you change the default '5m' here, also remember to change the default age validity in sinatra/cf_light_api.rb:31
UPDATE_TIMEOUT  = (ENV['UPDATE_TIMEOUT']  || '5m').to_s

lock_manager = Redlock::Client.new([ENV['REDIS_URI']])
scheduler    = Rufus::Scheduler.new

@logger.info "Update interval: '#{UPDATE_INTERVAL}'"
@logger.info "Update timeout:  '#{UPDATE_TIMEOUT}'"

if ENV['GRAPHITE_HOST'] and ENV['GRAPHITE_PORT']
  @logger.info "Graphite server: #{ENV['GRAPHITE_HOST']}:#{ENV['GRAPHITE_PORT']}" 
else
  @logger.info 'Graphite server: Disabled'
end

scheduler.every UPDATE_INTERVAL, :first_in => '5s', :overlap => false, :timeout => UPDATE_TIMEOUT do
  @cf_client = nil
  @graphite  = GraphiteAPI.new(graphite: "#{ENV['GRAPHITE_HOST']}:#{ENV['GRAPHITE_PORT']}") if ENV['GRAPHITE_HOST'] and ENV['GRAPHITE_PORT']

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
          # TODO: This is a bit repetative, could maybe improve?
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
            :data_from     => Time.now.to_i,
            :last_uploaded => app['metadata']['updated_at'] ? DateTime.parse(app['metadata']['updated_at']).strftime('%Y-%m-%d %T %z') : nil
          }

          # Add additional data, such as instance usage statistics, and routes - but this is only possible
          # if the instance is running.
          additional_data = {}

          begin
            instance_stats = []
            routes         = []
            if running
              # Finds the first running app instance that has a set of routes, in case there are stopped/crashed app instances that don't have any routes.
              instance_stats = formatted_instance_stats_for_app(app)
              running_instances = instance_stats.select{|instance| instance['stats']['uris'] if instance['state'] == 'RUNNING'}
              raise "Unable to retrieve app routes - no app instances are running." if running_instances.empty?
              
              routes = running_instances.first['stats']['uris']

              if @graphite
                send_instance_usage_data_to_graphite(instance_stats, org['entity']['name'], space['entity']['name'], app['entity']['name'])
              end
            end

            additional_data = {
             :running   => running,
             :instances => instance_stats,
             :routes    => routes,
             :error     => nil
            }

          rescue => e
            # Most exceptions here will be caused by the app or one of the instances being in a non-standard state,
            # for example, trying to query an app which was present when the worker began updating, but was stopped
            # before we reached this section, so we just catch all exceptions, log the reason and move on.
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
