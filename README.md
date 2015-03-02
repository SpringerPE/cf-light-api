# CF Light API

## What is this?

A super lightweight API for CloudFoundry. Why? Well the CF API contains all sorts of relations making it very heavy to query.

Having lots of api consumers for random scripts and dashboards makes it necessary to scale up the CF installation not to disrupt normal "cf cli operations".
So, lets just cache all the data we want in Redis for 5 minutes and serve that. Wiie. \o/

This gem provides a single binary `cf_light_api`, which starts a small Sinatra app to serve the HTTP requests, and also starts a background worker via the Rufus Scheduler, which updates Redis with the data from CF every 5 minutes.

## API Endpoints

The API just reads a stringified JSON from Redis and serves it under the following endpoints:

### /v1/apps

An array of JSON documents, for all applications running in every Org and Space in your CF environment. Each document has the following structure:

```json
{
  "guid": "app GUID",
  "name": "app_name",
  "org": "org name",
  "space": "space name",
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

**Note:** The `running` attribute may contain `true`, `false` or `error`. Applications in the latter state will have further information about the problem in the `error` attribute, which is `null` at all other times.
Memory and disk quota and usage figures are given in Bytes.

### /v1/orgs

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

**Note:** Memory limits for each org are given in Bytes.

## Worker

The worker basically gets all the data we want from the real API every 5 mins, puts in Redis and sleeps. The worker runs in a background thread via the Rufus Scheduler and is automatically started as part of the API.

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

3. You should now be able to start the CF Light API and worker by running `./cf_light_api`.

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
