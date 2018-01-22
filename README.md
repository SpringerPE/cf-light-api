# CF Light API

[![Gem Version](https://badge.fury.io/rb/cf_light_api.svg)](http://badge.fury.io/rb/cf_light_api)

## What is this?

A super lightweight API for CloudFoundry. Why? Well the CF API contains all sorts of relations making it very heavy to query.

Having lots of API consumers for random scripts and dashboards makes it necessary to scale up the CF installation not to disrupt normal "cf cli operations".
So, lets just cache all the data we want in Redis for 5 minutes and serve that. \o/

This gem provides a single binary `cf_light_api`, which starts a small Sinatra app to serve the HTTP requests, and also starts a background worker via the Rufus Scheduler, which updates Redis with the data from CF every 5 minutes.

## API Endpoints

The API just reads a stringified JSON from Redis and serves it under the following endpoints.

### Apps

There are currently two endpoints, the original (and now deprecated) "v1" and a new "v2" which offers more details and better error handling.

#### V2 - Current

`GET /v2/apps`

##### (Optional) Filtering by Org name

`GET /v2/apps/<org_name>`

##### Response

An array of JSON documents for all applications in the configured CF environment. If you provide an `org` parameter, the list will be filtered to contain only applications belonging to the given `org`. The majority of the document is identical to the response you would receive from a standard `/v2/apps` request made against the main CF API, but with some additional fields added on top:

* `created_at` - When the app was originally created, taken from the metadata.

* `updated_at` - When the app was last modified, taken from the metadata.

* `guid` - The app GUID, taken from the metadata.

* `instances` - An array of all instances associated with this application, their state and usage statistics

* `routes` - An array of all routes assigned to your app instances (also exposed via the `uris` attribute of each member of the `instances` attribute).

* `meta` - A document containing any error messages capturing during processing of this application.

* `stack` - The name of the container stack being used by the application, as a string.

* `space` - The name of the space this app belongs to, as a string.

* `org` - The name of the org this app belongs to, as a string.

* `environment_json` - An array of environment variables exposed to this application, if enabled as documented [here](#gathering-environment-variables).

Each document has the following structure:

```json
{
  "name": "app_name",
  "production": false,
  "space_guid": "c0af44b8-8b51-4db5-927e-ccad2e6dab54",
  "stack_guid": "7c5b664c-e9b8-457b-83a4-6092b7372494",
  "buildpack": null,
  "detected_buildpack": "Ruby",
  "detected_buildpack_guid": "44ec3a97-0d94-4ebb-ad33-e9ee837515bd",
  "environment_json": {},
  "memory": 64,
  "instances": [
    {
      "state": "RUNNING",
      "stats": {
        "name": "app_name",
        "uris": [
          "app_name.yourdomain.com"
        ],
        "host": "ip address",
        "port": "port number",
        "uptime": 2889203,
        "mem_quota": 67108864,
        "disk_quota": 1073741824,
        "fds_quota": 16384,
        "usage": {
          "time": "2018-01-19T15:54:48.254719257Z",
          "cpu": 0.00012013292649106141,
          "mem": 43802624,
          "disk": 78118912
        }
      }
    }
  ],
  "disk_quota": 1024,
  "state": "STARTED",
  "version": "45c81548-3d3d-4152-bbc5-6b86eba4d5df",
  "command": null,
  "console": false,
  "debug": null,
  "staging_task_id": "ba623c5c-18e1-4d6e-b331-aedf244cb493",
  "package_state": "STAGED",
  "health_check_type": "port",
  "health_check_timeout": null,
  "health_check_http_endpoint": null,
  "staging_failed_reason": null,
  "staging_failed_description": null,
  "diego": true,
  "docker_image": null,
  "docker_credentials": {
    "username": null,
    "password": null
  },
  "package_updated_at": "2017-06-13T12:19:37Z",
  "detected_start_command": "bundle exec rackup config.ru -p $PORT",
  "enable_ssh": false,
  "ports": [
    8080
  ],
  "space_url": "/v2/spaces/c0af44b8-8b51-4db5-927e-ccad2e6dab54",
  "stack_url": "/v2/stacks/7c5b664c-e9b8-457b-83a4-6092b7372494",
  "stack": "cflinuxfs2",
  "routes_url": "/v2/apps/ba623c5c-18e1-4d6e-b331-aedf244cb493/routes",
  "routes": [
    "app_name.yourdomain.com"
  ],
  "events_url": "/v2/apps/ba623c5c-18e1-4d6e-b331-aedf244cb493/events",
  "service_bindings_url": "/v2/apps/ba623c5c-18e1-4d6e-b331-aedf244cb493/service_bindings",
  "route_mappings_url": "/v2/apps/ba623c5c-18e1-4d6e-b331-aedf244cb493/route_mappings",
  "created_at": "2015-04-22T12:07:56Z",
  "updated_at": "2016-12-20T10:02:47Z",
  "guid": "ba623c5c-18e1-4d6e-b331-aedf244cb493",
  "running": true,
  "environment_variables": {},
  "meta": {
    "error": false
  },
  "space": "space name",
  "org": "org name"
}
```

##### Errors

If there are any errors processing a given application, details on the error will be captured and exposed in the `meta` attribute, for example:

```
"meta": {
  "error": true,
  "type": "CFResponseError",
  "message": "Code 200003: CF-AppStoppedStatsError - Could not fetch stats for stopped app: <name of app here>",
  "backtrace": [
    "etc...", "etc...", "etc..."
  ]
}
```

If there are no errors, the `meta` attribute will instead look like this:

```
"meta": {
  "error": false
}
```

##### Notes

* The `running` attribute is a boolean and will be `true` if there is at least one instance of your app with the state of `RUNNING`.

* Memory, disk quota and usage figures are given in bytes.

* If the buildpack is not known, the `buildpack` attribute will be `null`.

* If the last uploaded time is not known, the `last_uploaded` attribute will be `null`.

* The `diego` attribute is a boolean which will be `true` if the application is running on a Diego Cell, or `false` if running on a DEA Node. See the Cloud Foundry [docs](https://docs.cloudfoundry.org/concepts/diego/dea-vs-diego.html) for more information on these two architectures.

* There is an optional `environment_json` attribute which only appears if the feature is enabled - please see the [Gathering Environment Variables](#gathering-environment-variables) section below for more information.

#### V1 - Deprecated

`GET /v1/apps`

##### (Optional) Filtering by Org name

`GET /v1/apps/<org_name>`

##### Response

An array of JSON documents for all applications in the configured CF environment. If you provide an `org` parameter, the list will be filtered to contain only applications belonging to the given `org`. Each document has the following structure:

```json
{
  "guid": "app GUID",
  "name": "app_name",
  "org": "org name",
  "space": "space name",
  "stack": "lucid64",
  "buildpack": "https://github.com/cloudfoundry/ruby-buildpack.git",
  "diego": false,
  "docker": false,
  "docker_image": null,
  "routes": [
    "app_name.yourdomain.com"
  ],
  "data_from": "unix timestamp of last update",
  "last_uploaded": "2016-02-04 15:21:25 +0000",
  "state": "STARTED",
  "running": true,
  "instances": [
    {
      "state": "RUNNING",
      "stats": {
        "name": "app_name",
        "uris": [
          "app_name.yourdomain.com"
        ],
        "host": "ip address",
        "port": "port number",
        "uptime": 1979434,
        "mem_quota": 268435456,
        "disk_quota": 268435456,
        "fds_quota": 16384,
        "usage": {
          "time": "2015-02-27 16:52:35 +0000",
          "cpu": 0.0,
          "mem": 134217728,
          "disk": 134217728
        }
      }
    }
  ],
  "error": null
}
```

##### Notes

* The `running` attribute may contain `true`, `false` or `error`. Applications in the latter state will have further information about the problem in the `error` attribute, which is `null` at all other times.

* Memory, disk quota and usage figures are given in bytes.

* If the buildpack is not known, the `buildpack` attribute will be `null`.

* If the last uploaded time is not known, the `last_uploaded` attribute will be `null`.

* The `diego` attribute is a boolean which will be `true` if the application is running on a Diego Cell, or `false` if running on a DEA Node. See the Cloud Foundry [docs](https://docs.cloudfoundry.org/concepts/diego/dea-vs-diego.html) for more information on these two architectures.

* The `docker` attribute is a boolean which will be `true` if the application was deployed from a Docker image, or `false` if it was deployed using a buildpack. If `true`, the `docker_image` attribute will then show the Docker image used, otherwise it will be `null`.

* There is an optional `environment_variables` attribute which only appears if the feature is enabled - please see the section of Gathering Environment Variables below for more information.

### Organisations

`GET /v1/orgs`

#### (Optional) Filtering by Org GUID

`GET /v1/orgs/<guid>`

#### Response

An array of JSON documents, for all organisations in your CF environment. If you provide an `guid` parameter, the list will be filtered to contain only the organisation with the given `guid`. Each document has the following structure:

```json
{
  "guid": "org GUID",
  "name": "my_org_name",
  "quota": {
    "total_services": 50,
    "memory_limit": 10737418240
  }
}
```

##### Notes

* Memory limits for each org are given in bytes.

### Last Updated

`GET /v1/last_updated`

####

A single JSON document showing the last time the data was updated by the worker:

```json
{
  "last_updated": "2015-11-07 01:25:28 +0000"
}
```

If the data was not updated within a configurable time period, the HTTP status will be `503 Service Unavailable`.

### Info

`GET /v1/info`

#### Response

A single JSON document showing various pieces of information about the CF installation. This data comes unmodified from CF's own `/v2/info` endpoint.

```json
{
  "name": "vcap",
  "build": "2222",
  "support": "http://support.cloudfoundry.com",
  "version": 2,
  "description": "Cloud Foundry sponsored by Pivotal",
  "authorization_endpoint": "http://localhost:8080/uaa",
  "token_endpoint": "http://localhost:8080/uaa",
  "min_cli_version": "6.20.0",
  "min_recommended_cli_version": "6.21.0",
  "api_version": "2.94.0",
  "app_ssh_endpoint": "ssh.system.domain.example.com:2222",
  "app_ssh_host_key_fingerprint": "47:0d:d1:c8:c3:3d:0a:36:d1:49:2f:f2:90:27:31:d0",
  "app_ssh_oauth_client": null,
  "routing_endpoint": "http://localhost:3000",
  "doppler_logging_endpoint": "wss://doppler.vcap.me:4443",
  "logging_endpoint": "ws://loggregator.vcap.me:80"
}
```

## Worker

The worker basically gets all the data we want from the real API every 5 mins, puts in Redis and sleeps. The worker runs in a background thread via the Rufus Scheduler and is automatically started as part of the API. There is basic locking implemented via Redis to allow you to run multiple instances of `cf_light_api` alongside one another, without duplicating work.

## Usage

1. You must first set the following environment variables:
```bash
  export REDIS_URI=redis://redis.yourdomain.com:6379/
  export REDIS_KEY_PREFIX=cf_light_api_live  #useful if you are sharing a single Redis database)
  export CF_API=https://api.cf.yourdomain.com
  export CF_USER=username
  export CF_PASSWORD=password
```

2. In a new Ruby project, create a Gemfile containing the following:
```ruby
  ruby '2.0.0'
  source 'https://rubygems.org'

  gem 'cf_light_api'
```
Then run `bundle install`.

3. You should now be able to start the CF Light API and worker by running `cf_light_api`.

## Deploying to Cloud Foundry

1. Create a `manifest.yml` in the Ruby project you just created, containing the following:
```yml
---
applications:
  - name: cf-light-api
    instances: 2
    memory: 128MB
    env:
      REDIS_URI: redis://redis.yourdomain.com:6379/
      REDIS_KEY_PREFIX: cf_light_api_live
      CF_API: https://api.cf.yourdomain.com
      CF_USER: username
      CF_PASSWORD: password
```

2. Then simply `cf push` when logged in to your CF environment.

## Customisation

### Debug Logs

You can enable more verbose debug logs by setting the following environment variable:

`export DEBUG=true`

### Update Frequency and Timeout

The default is to update data every 5 minutes, with a 5 minute timeout. You can modify this behaviour by setting the following environment variables:

`export UPDATE_INTERVAL='10m'`
`export UPDATE_TIMEOUT='7m'`

Any option which is valid for [Rufus Scheduler](https://github.com/jmettraux/rufus-scheduler) durations will work here, for example `30s`, `1m` or `1d`.

If you change these settings, you will also need to adjust the data age validity, as described below.

### Update Parallelisation

For larger Cloud Foundry deployments, you may wish to increase the number of threads (from the default of `1`) used to gather application data by setting the following environment variable:

`export UPDATE_THREADS=4`

Note that this will of course increase the number of simultaneous requests made to your main Cloud Foundry API.

### Data Age Validity

By default, the data is considered valid if it was last updated within 10 minutes (twice the default update interval). You can modify this behaviour by setting the following environment variable (in seconds):

`export DATA_AGE_VALIDITY=3600`

### Export data to Graphite

Usage statistics for each app instance and org quota details can be exported to Graphite by setting the following environment variables:

`export GRAPHITE_HOST=graphiteserver.domain.com`
`export GRAPHITE_PORT=2003`
`export CF_ENV_NAME=live`

If you have specified the The Graphite schema will look like this:

```
"cf_apps.#{cf_env_name}.#{org_name}.#{space_name}.#{app_name}.#{app_instance_index}.#{cpu|mem|disk|mem_quota|disk_quota}"
"cf_orgs.#{cf_env_name}.#{org_name}.quota.#{total_services|total_routes|memory_limit}"
```

### New Relic Integration

Instrumentation regarding the API and the backend worker can be made available in New Relic if you enable this integration by setting the following environment variables:

```
export NEW_RELIC_LICENSE_KEY=<license key goes here>
export NEW_RELIC_APP_NAME="CF Light API"
```

### Gathering Environment Variables

You can gather all user-provided environment variables for each application by enabling the feature with an environment variable:

```
export EXPOSE_ENVIRONMENT_VARIABLES=true
```

If you want to filter out sensitive environment variables, you can also set an optional whitelist, to capture only the environment variables you specify via a comma-seperated list of one or more strings:

```
export ENVIRONMENT_VARIABLES_WHITELIST="MY_ENV_VAR, A_SECOND_ENV_VAR"
```

The matching data will be exposed in an `environment_variables` attribute in the response to `/v1/apps`. If this feature is not explicitly enabled, the attribute will not be present at all. If you enable the feature with a whitelist and there are no matches, this attribute will contain an empty document `{}`.

## Development

Source hosted at [GitHub](https://github.com/springerpe/cf-light-api).
Report issues and feature requests on [GitHub Issues](https://github.com/springerpe/cf-light-api/issues).

### Note on Patches / Pull Requests

 * Fork the project.
 * Make your feature addition or bug fix, ideally committing to a topic branch.
 * Please document your changes in the README, but don't change the version, or changelog.
 * Send a pull request.

## Copyright

Copyright (c) Springer Nature. See [LICENSE](https://github.com/springerpe/cf-light-api/blob/master/LICENSE) for details.
