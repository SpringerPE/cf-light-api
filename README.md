# CF Light API

[![Gem Version](https://badge.fury.io/rb/cf_light_api.svg)](http://badge.fury.io/rb/cf_light_api)

## What is this?

A super lightweight API for CloudFoundry. Why? Well the CF API contains all sorts of relations making it very heavy to query.

Having lots of api consumers for random scripts and dashboards makes it necessary to scale up the CF installation not to disrupt normal "cf cli operations".
So, lets just cache all the data we want in Redis for 5 minutes and serve that. Wiie. \o/

This gem provides a single binary `cf_light_api`, which starts a small Sinatra app to serve the HTTP requests, and also starts a background worker via the Rufus Scheduler, which updates Redis with the data from CF every 5 minutes.

## API Endpoints

The API just reads a stringified JSON from Redis and serves it under the following endpoints.

### Apps

`GET /v1/apps`

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| `org` | `string` | (Optional) Filter the applications by organisation name |

#### Response

An array of JSON documents for all applications in the configured CF environment. If you provide an `org` parameter, the list will be filtered to show only applications belonging to the given `org`. Each document has the following structure:

```json
{
  "guid": "app GUID",
  "name": "app_name",
  "org": "org name",
  "space": "space name",
  "stack": "lucid64",
  "buildpack": "https://github.com/cloudfoundry/ruby-buildpack.git",
  "routes": [
    "app_name.yourdomain.com"
  ],
  "data_from": "timestamp of last update",
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

##### Notes

* The `running` attribute may contain `true`, `false` or `error`. Applications in the latter state will have further information about the problem in the `error` attribute, which is `null` at all other times.
* Memory, disk quota and usage figures are given in bytes.
* If the buildpack is not known, the `buildpack` attribute will be `null`.

### Organisations

`GET /v1/orgs`

#### Response

An array of JSON documents, for all organisations in your CF environment. Each document has the following structure:

```json
{
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

## Deploying to CloudFoundry

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

### Parallel Processes

The worker collects the data using parallel processes to speed up the processes. By default, it will use 4 parallel processes for each of three nested maps. You can change the number by setting the following environment variable:

`export PARALLEL_MAPS=6`

### Update Frequency and Timeout

The default is to update data every 5 minutes, with a 5 minute timeout. You can modify this behaviour by setting the following environment variables:

`export UPDATE_INTERVAL='10m'`
`export UPDATE_TIMEOUT='7m'`

Any option which is valid for [Rufus Scheduler](https://github.com/jmettraux/rufus-scheduler) durations will work here, for example `30s`, `1m` or `1d`.

## Development

Source hosted at [GitHub](https://github.com/springerpe/cf-light-api).
Report issues and feature requests on [GitHub Issues](https://github.com/springerpe/cf-light-api/issues).

### Note on Patches / Pull Requests

 * Fork the project.
 * Make your feature addition or bug fix, ideally committing to a topic branch.
 * Please document your changes in the README, but don't change the version, or changelog.
 * Send a pull request.

## Copyright

Copyright (c) Springer. See [LICENSE](https://github.com/springerpe/cf-light-api/blob/master/LICENSE) for details.
