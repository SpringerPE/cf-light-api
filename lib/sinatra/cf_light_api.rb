module Sinatra
  module CfLightAPI

    def self.registered(app)
      app.get '/v1/apps/?' do
        content_type :json
        REDIS.get "#{ENV['REDIS_KEY_PREFIX']}:apps"
      end

      app.get '/v1/orgs/?' do
        content_type :json
        REDIS.get "#{ENV['REDIS_KEY_PREFIX']}:orgs"
      end
    end

  end

  register CfLightAPI
end
