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

scheduler.every UPDATE_INTERVAL, :first_in => '5s', :overlap => false, :timeout => UPDATE_TIMEOUT do
  cf_client = nil
  graphite  = GraphiteAPI.new(graphite: ENV['GRAPHITE']) if ENV['GRAPHITE']

  begin
    lock_manager.lock("#{ENV['REDIS_KEY_PREFIX']}:lock", 5*60*1000) do |lock|
      if lock
        start_time = Time.now

        @logger.info "Updating data in parallel..."

        cf_client = get_client()

        org_data = get_org_data(cf_client)
        app_data = get_app_data(cf_client, graphite)

        put_in_redis "#{ENV['REDIS_KEY_PREFIX']}:orgs", org_data
        put_in_redis "#{ENV['REDIS_KEY_PREFIX']}:apps", app_data
        put_in_redis "#{ENV['REDIS_KEY_PREFIX']}:last_updated", {:last_updated => Time.now}

        @logger.info "Update completed in #{format_duration(Time.now.to_f - start_time.to_f)}..."
        lock_manager.unlock(lock)
        cf_client.logout
      else
        @logger.info "Update already running in another instance!"
      end
    end
  rescue Rufus::Scheduler::TimeoutError
    @logger.info 'Data update took too long and was aborted, waiting for the lock to expire before trying again...'
    cf_client.logout
  end
end

def get_client(cf_api=ENV['CF_API'], cf_user=ENV['CF_USER'], cf_password=ENV['CF_PASSWORD'])
  client = CFoundry::Client.get(cf_api)
  client.login({:username => cf_user, :password => cf_password})
  client
end

def send_data_to_graphite(data, graphite)
  org   = data[:org]
  space = data[:space]
  name  = data[:name].sub ".", "_" # Some apps have dots in the app name

  data[:instances].each_with_index do |instance_data, index|
    graphite_base_key = "cf_apps.#{org}.#{space}.#{name}.#{index}"

    # Quota data
    [:mem_quota, :disk_quota].each do |key|
      graphite.metrics "#{graphite_base_key}.#{key}" => instance_data[:stats][key]
    end

    # Usage data
    [:mem, :disk, :cpu].each do |key|
      graphite.metrics "#{graphite_base_key}.#{key}" => instance_data[:stats][:usage][key]
    end
  end
end

def get_app_data(cf_client, graphite)
  Parallel.map(cf_client.organizations, :in_threads=> PARALLEL_MAPS) do |org|
    org_name = org.name
    Parallel.map(org.spaces, :in_threads => PARALLEL_MAPS) do |space|
      space_name = space.name
      @logger.info "Getting app data for apps in #{org_name}:#{space_name}..."
      Parallel.map(space.apps, :in_threads=> PARALLEL_MAPS) do |app|
        begin
          # It's possible for an app to have been terminated before this stage is reached.
          formatted_app_data = format_app_data(app, org_name, space_name)
          if graphite
            send_data_to_graphite(formatted_app_data, graphite)
          end
          formatted_app_data
        rescue CFoundry::AppNotFound
          next
        end
      end
    end
  end.flatten.compact
end

def get_org_data(cf_client)
  Parallel.map( cf_client.organizations, :in_threads=> PARALLEL_MAPS) do |org|
    @logger.info "Getting org data for #{org.name}..."
    # The CFoundry client returns memory_limit in MB, so we need to normalise to bytes to match the Apps.
    {
      :guid => org.guid,
      :name => org.name,
      :quota => {
        :total_services => org.quota_definition.total_services,
        :memory_limit   => org.quota_definition.memory_limit * 1024 * 1024
      }
    }
  end.flatten.compact
end

def format_app_data(app, org_name, space_name)

  last_uploaded = (app.manifest[:entity][:package_updated_at] ||= nil)

  base_data = {
    :guid          => app.guid,
    :name          => app.name,
    :org           => org_name,
    :space         => space_name,
    :stack         => app.stack.name,
    :buildpack     => app.buildpack,
    :routes        => app.routes.map {|route| route.name},
    :data_from     => Time.now.to_i,
    :last_uploaded => last_uploaded ? DateTime.parse(last_uploaded).strftime('%Y-%m-%d %T %z') : nil
  }

  additional_data = {}
  begin
    additional_data = {
     :running   => app.running?,
     :instances => app.running? ? app.stats.map{|key, value| value} : [],
     :error     => nil
    }
  rescue => e
    @logger.info "  #{org_name} #{space_name}: '#{app.name}'' error: #{e.message}"
    additional_data = {
      :running   => 'error',
      :instances => [],
      :error     => e.message
    }
  end

  base_data.merge additional_data
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
