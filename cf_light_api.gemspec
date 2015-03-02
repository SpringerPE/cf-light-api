Gem::Specification.new 'cf_light_api', '1.0.0' do |s|
  s.summary     = 'A super lightweight API for reading App and Org data from CloudFoundry, cached in Redis.'
  s.description = 'A super lightweight API for reading App and Org data from CloudFoundry, cached in Redis.'
  
  s.authors     = ['Springer Platform Engineering']
  s.email       = ''
  s.homepage    = "https://github.com/springerpe/cf-light-api"
  s.license     = 'MIT'
  s.files       = [ './lib/sinatra/cf_light_api.rb',
                    './lib/cf_light_api/redis.rb',
                    './lib/cf_light_api/worker.rb' ]
  s.executables = 'cf_light_api'

  s.add_dependency 'cfoundry',        '~> 4.7.1'
  s.add_dependency 'redis',           '~> 3.2.1'
  s.add_dependency 'rufus-scheduler', '~>3.0.9'
  s.add_dependency 'sinatra',         '~> 1.4.5'
end
