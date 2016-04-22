require 'json'

module Sinatra
  module CfLightAPI

    def self.registered(app)
      app.get '/v1/apps/?:org?' do
        content_type :json
        all_apps = JSON.parse(REDIS.get("#{ENV['REDIS_KEY_PREFIX']}:apps"))

        if params[:org]
          return all_apps.select{|an_app| an_app['org'] == params[:org]}.to_json
        end

        return all_apps.to_json
      end

      app.get '/v1/orgs/?:guid?' do
        content_type :json
        all_orgs = JSON.parse(REDIS.get("#{ENV['REDIS_KEY_PREFIX']}:orgs"))

        if params[:guid]
          return all_orgs.select{|an_org| an_org['guid'] == params[:guid]}.to_json
        end

        return all_orgs.to_json
      end

      app.get '/v1/last_updated' do
        content_type :json
        updated_json = REDIS.get("#{ENV['REDIS_KEY_PREFIX']}:last_updated")

        last_updated         = DateTime.parse JSON.parse(updated_json)["last_updated"]
        seconds_since_update = ((DateTime.now - last_updated) * 24 * 60 * 60).to_i

        status 503 if seconds_since_update >= (ENV['DATA_AGE_VALIDITY'] || '600'.to_i)
        return updated_json
      end
    end

  end

  register CfLightAPI
end
