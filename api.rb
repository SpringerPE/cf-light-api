require 'sinatra'
require 'redis'

get '/' do
  redirect to('/v1/')
end

get '/v1/' do
  content_type :json
  redis = Redis.new(:url => ENV['redis_uri'])
  redis.get ENV['redis_key']
end
