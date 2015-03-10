require 'cfoundry'
require 'json'
require 'rufus-scheduler'
require 'parallel'

['CF_API', 'CF_USER', 'CF_PASSWORD'].each do |env|
  puts "[cf_light_api:worker] Error: please set the '#{env}' environment variable." unless ENV[env]
  next
end

scheduler = Rufus::Scheduler.new
scheduler.every '5m', :first_in => '5s', :overlap => false, :timeout => '5m' do
  begin
    if locked?
      puts "[cf_light_api:worker] Data update is already running in another worker, skipping..."
      next
    end

    lock
    start_time = Time.now

    puts "[cf_light_api:worker] Updating data..."

    cf_client = get_client()

    org_data = []
    app_data = []
    org_data = Parallel.map( cf_client.organizations, :in_processes => 4) do |org|
      # The CFoundry client returns memory_limit in MB, so we need to normalise to Bytes to match the Apps.
      { 
        :name => org.name,
        :quota => {
          :total_services => org.quota_definition.total_services,
          :memory_limit   => org.quota_definition.memory_limit * 1024 * 1024
        }
      }
    end.flatten

    app_data = Parallel.map(cf_client.organizations, :in_processes => 4) do |org|
      Parallel.map(org.spaces, :in_processes => 4) do |space|
        Parallel.map(space.apps, :in_processes => 4) do |app|
          begin
            # It's possible for an app to have been terminated before this stage is reached.
            format_app_data(app, org.name, space.name)
          rescue CFoundry::AppNotFound
            next
          end
        end
      end
    end.flatten

    unlock

    put_in_redis "#{ENV['REDIS_KEY_PREFIX']}:orgs", org_data
    put_in_redis "#{ENV['REDIS_KEY_PREFIX']}:apps", app_data

    puts "[cf_light_api:worker] Update completed in #{format_duration(Time.now.to_f - start_time.to_f)}..."

  rescue Rufus::Scheduler::TimeoutError
    puts '[cf_light_api:worker] Data update took too long and was aborted...'
  end
end

def locked?
  REDIS.get("#{ENV['REDIS_KEY_PREFIX']}:lock") ? true : false
end

def lock
  REDIS.set "#{ENV['REDIS_KEY_PREFIX']}:lock", true
  REDIS.expire "#{ENV['REDIS_KEY_PREFIX']}:lock", 900
end

def unlock
  REDIS.del "#{ENV['REDIS_KEY_PREFIX']}:lock"
end

def get_client(cf_api=ENV['CF_API'], cf_user=ENV['CF_USER'], cf_password=ENV['CF_PASSWORD'])
  client = CFoundry::Client.get(cf_api)
  client.login({:username => cf_user, :password => cf_password})
  client
end

def format_app_data(app, org_name, space_name)
  base_data = {
    :guid      => app.guid,
    :name      => app.name,
    :org       => org_name,
    :space     => space_name,
    :routes    => app.routes.map {|route| route.name},
    :data_from => Time.now.to_i,
  }

  additional_data = {}
  begin
    additional_data = {
     :running   => app.running?,
     :instances => app.running? ? app.stats.map{|key, value| value} : [],
     :error     => nil
    }
  rescue => e
    puts "[cf_light_api:worker] #{org_name} #{space_name}: '#{app.name}'' error: #{e.message}"
    additional_data = {
      :running   => 'error',
      :instances => [],
      :error     => e.message
    }
  end

  base_data.merge additional_data
end

def put_in_redis(key, data)
  puts "[cf_light_api:worker] Putting data #{data} into redis key #{key}"
  REDIS.set key, data.to_json
end

def format_duration(elapsed_seconds)
  seconds = elapsed_seconds % 60
  minutes = (elapsed_seconds / 60) % 60
  hours   = elapsed_seconds / (60 * 60)
  format("%02d hrs, %02d mins, %02d secs", hours, minutes, seconds)
end
