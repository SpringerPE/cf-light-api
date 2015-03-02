require 'redis'

['REDIS_URI', 'REDIS_KEY_PREFIX'].each do |env|
  abort "[cf_light_api] Error: please set the '#{env}' environment variable." unless ENV[env]
end

puts "[cf_light_api] Using Redis at '#{ENV['REDIS_URI']}' with key '#{ENV['REDIS_KEY_PREFIX']}'"

REDIS = Redis.new :url => ENV['REDIS_URI']
