require 'json'

module Sinatra
  module CfLightAPI

    def self.registered(app)
      app.get '/v1/apps/?:org?' do
        all_apps = JSON.parse(REDIS.get("#{ENV['REDIS_KEY_PREFIX']}:apps"))

        content_type :json

        if params[:org]
          return all_apps.select{|an_app| an_app['org'] == params[:org]}.to_json
        end

        return all_apps.to_json
      end

      app.get '/v1/orgs/?' do
        content_type :json
        REDIS.get "#{ENV['REDIS_KEY_PREFIX']}:orgs"
      end
    end

  end

  register CfLightAPI
end
