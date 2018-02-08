# 3.0.0

We've refactored the worker to improve error handling, and to make it possible to capture errors from CF during processing of each app, so we can propagate this out to the consumers.

Furthermore, we now also capture the entire response from Cloud Foundry, for each app, rather than mapping only a subset of the attributes, this should allow consumers to make more informed decisions with the data.

Contains several features and bugfixes, tested via several pre-release versions:

Features (3.0.0.pre1 - January 22, 2018):

  - New `/v2/apps` endpoint which returns all the app data available from CF, rather than a subset of the fields as before.

  - New `meta` attribute present for each app in `/v2/apps`, which contains details of any errors encountered when processing the relevant app.

  - Adjusted default log levels to be less noisy, and added an option to enable debug logging via a `DEBUG` environment variable when needed.

Deprecated:

  - The `/v1/apps` endpoint remains, but should now be considered deprecated.

Bugfixes:

  - (3.0.0.pre8 - January 29, 2018): Ensure the `routes` and `instances` attributes are once again always present in the `/v1/apps` endpoint.

  - (3.0.0.pre7 (January 24, 2018))  - In order to avoid an exception, we only pass through running instances when formatting usage stats to be sent to Graphite.

  - 3.0.0.pre6 (January 23, 2018) - Don't attempt to send formatted instance stats to Graphite when there are no instances.

  - 3.0.0.pre5 (January 23, 2018) - Fixed a scoping issue when checking if there is at least one running instance.

  - 3.0.0.pre4 (January 23, 2018) - Restoring Graphite functionality, which was disabled in the previous pre-release versions pre1, pre2 and pre3.

  - 3.0.0.pre3 (January 23, 2018) - We no longer try to gather app instance stats, if the app state is 'STOPPED'.

  - 3.0.0.pre2 (January 23, 2018) - Fixes a regression to do with Graphite metrics when certain inline-relations are not present in the app object, for example "stack".

# 2.6.0 (December 4th, 2017)

Contains several features and bugfixes, tested via the following pre-release versions:

## 2.6.0.pre4

Features:

  - Upgraded some of our dependencies to the latest versions.

## 2.6.0.pre3

Bugfixes:

  - Ensure the response from CF is a valid JSON object, and correctly handle this as an error if it is not.
  - Added error handling to the domain lookup logic for app routes.
  - Stacktraces are now logged along with the error message, when rescuing from StandardError.

## 2.6.0.pre2 (November 29, 2017)

Bugfixes:

  - Fixed a bug when sending worker update duration to Graphite.

## 2.6.0.pre1 (November 29, 2017)

Features:

  - Reintroduced the parallelisation option when gathering app data, to speed things up for larger Cloud Foundry deployments. Defaults to the current behaviour of a single thread.
  - The duration of the worker update is now sent to Graphite under a new key `cf_light_api.${cf_environment}.update_duration`. It is given in seconds, or `0` if the timeout was reached during the update.

Bugfixes:

  - Fixed a bug where TimeoutErrors were being caught at the wrong level, and causing an `error` state to be set for apps which were actually running, resulting in the API returning incorrect data.

# 2.5.1 (November 21, 2017)

Features:

  - Adds an additional endpoint `/v1/info` which returns the unmodified response from CF's own `/v2/info` endpoint, containing various useful bits of information about your CF installation.

Bugfixes:

  - Sometimes route gathering would fail for apps in certain edge case states, this should now be handled gracefully instead of causing the data update to fail.

# 2.5.0 (June 19, 2017)

Features:

  - Adds an additional opt-in attribute to the response for `/v1/apps`:
    * `environment_variables`
      A dictionary containing an app's environment variables. This feature must be enabled explicitly and can also be configured with a whitelist to protect sensitive environment variables from being exposed.

# 2.4.0 (January 16, 2017)

Features:

  - Send organisation quota details to Graphite (when enabled).

# 2.3.0 (January 11, 2017)

Features:

  - Changed the Graphite key path to include the CF environment name, so users with more than one Cloud Foundry deployment can group metrics by deployment.

# 2.2.1.pre1 (November 30, 2016)

Bugfixes:

  - Fix an issue with sanitising the app name for Graphite if it included `.`, which was also altering the app name when reported by the API itself.

# 2.2.0.pre1 (November 24, 2016)

Features:

  - Instrumentation regarding the API and the backend worker is now available thanks to new integration with New Relic.

# 2.1.0 (August 9, 2016)

Features:

  - Improves routes gathering, so an application's routes are now available even if no instances of the app are running. Previously this would not have been possible, as the routes were being retrieved from a running app instance's `uri` attribute.
  - Adds support for some additional attributes in the response to `/v1/apps`
    * `diego`
      A boolean showing whether the application is running on a Diego Cell.
    * `docker`
      A boolean showing whether the application was deployed from a Docker image.
    * `docker_image`
      A string showing the name of the Docker image used if `docker` is `true`, otherwise is set to `null`.
    * `state`
      The requested state as reported by Cloud Foundry, for example `STARTED`.

# 2.0.0 (June 14, 2016)

Features:

  - Large refactoring to replace the CFoundry ORM with simpler calls to the CF REST API instead.
    - Avoids the nested parallel maps required previously to speed up data collection.
    - Significantly reduces the number of requests being made against the CF API.
    - More predictable / linear CF API usage, number of requests is essentially the same as the number of apps.

Bugfixes:

  - Fixes issue #11 "Apps with more than one dot in their name do not get properly substituted".
  - Fixes issue #12 "Undefined method 'call' when exiting the worker via 'ctrl+c'".

# 2.0.0.pre2 (June 9, 2016)

Work in progress, released as `pre2` for general testing before being finalised.

Features:

  - Restored the 'Send to Graphite' functionality, which was not implemented in `pre1`.

Bugfixes:

  - Fixes issue #11 "Apps with more than one dot in their name do not get properly substituted".

# 2.0.0.pre1 (May 19, 2016)

Work in progress, released as `pre1` for general testing before being finalised.

Features:

  - Large refactoring to replace the CFoundry ORM with simpler calls to the CF REST API instead.
    - Avoids the nested parallel maps required previously to speed up data collection.
    - Significantly reduces the number of requests being made against the CF API.
    - More predictable / linear CF API usage, number of requests is essentially the same as the number of apps.

Bugfixes:

  - Fixes issue #12 "Undefined method 'call' when exiting the worker via 'ctrl+c'".

Known Issues:

  - 'Send to Graphite' functionality is not implemented in this pre-release.

# 1.7.0 (Apr 22, 2016)

Features:

  - Now includes the guid for each organisation when calling `/v2/orgs`
  - Implemented filtering by organisation guid in the `/v1/orgs` endpoint.

# 1.6.7 (Feb 4, 2016)

Bugfixes:

  - Some apps did not have a `last_uploaded` time, which is now being handled properly.

# 1.6.6 (Feb 4, 2016)

Features:

  - Now includes the `last_uploaded` time when formatting app data, which shows when an app was last pushed.

# 1.6.5 (Jan 8, 2016)

Features:

  - Made the data age validity configurable by setting the `DATA_AGE_VALIDITY` environment variable. It defaults to 10 minutes.
  - Moved the functionality of the `/internal/status` into `/v1/last_updated` and removed the endpoint.

# 1.6.4 (Jan 5, 2015)

Features:

  - Implement a /internal/status that returns a 503 if the data is older than 5 minutes, 200 otherwise.

# 1.6.3 (Dec 23, 2015)

Features:

  - Use threads instead of processes to lower the memory consumption.

# 1.6.2 (Dec 8, 2015)

Bugfixes:

  - Ensure the worker exits with failure unless all required environment variables are set.

# 1.6.1 (Dec 8, 2015)

Featues:

- Included `memory_quota` and `disk_quota` to the metrics being sent to Graphite.

# 1.6.0 (Dec 4, 2015)

Features:

  - Added support to send app instance stats data (cpu, memory and disk) to Graphite.

# 1.5.0 (Nov 9, 2015)

Features:

  - Retrieves the buildpack when formatting app data, where available.

# 1.4.0 (Nov 7, 2015)

Features:

  - Implemented new endpoint `/v1/last_updated` which shows the last time the data was updated by the worker.
  - Made the update interval and update timeout configurable.

Bugfixes:

  - Fixed an issue where the worker lock was not released when reaching the update timeout.

# 1.3.5 (Nov 6, 2015)

Bugfixes:

  - The default number of parallel map processes was being set incorrectly.

# 1.3.4 (Nov 4, 2015)

Features:

  - Sets a key in Redis showing the last update time.

# 1.3.3 (Nov 4, 2015)

Features:

  - Made the number of parallel map processes configurable.

# 1.3.2 (May 27, 2015)

Features:

  - Implemented worker locking via `redlock` gem.
  - Improved worker logging and refactored code for clarity.

Bugfixes:

  - Fixes issue #6 "Occasional 'null' entries in JSON response".

# 1.3.1 (Apr 28, 2015)

Features:

  - The `stack` attribute is now shown for all apps.

# 1.3.0 (Mar 20, 2015)

Features:

  - Implemented filtering by organisation name in the `/v1/apps` endpoint.

# 1.2.1 (Mar 10, 2015)

Bugfixes:

  - Fixed an issue where the scheduled job timeout in the worker did not match the lock expiry.
  - Disabled STDOUT output buffering, which made debugging harder in certain deployment environments.

# 1.2.0 (Mar 9, 2015)

Features:

  - Parallelised the background worker, to speed up metrics gathering. With our test CF org containing around 125 apps, the worker now takes around 30-40 seconds, instead of over 5 minutes to complete.

Bugfixes:

  - Handles `CFoundry::AppNotFound` exceptions, which can occur when an app is terminated whilst we're trying to retrieve it's usage statistics.

# 1.1.1 (Mar 6, 2015)

Features:

  - Logs the duration of the worker update process after each run.

# 1.1.0 (Mar 5, 2015)

Features:

  - Added locking to the worker, to allow multiple instances of `cf_light_api` to run alongside one another, without duplicating work.

# 1.0.0 (Mar 2, 2015)

Features:

  - Added new `/v1/orgs` endpoint for listing all Organisations and their quotas.
  - Re-packaged as a Ruby Gem and released on RubyGems.org.
  - More detailed documentation for endpoints.

# Not versioned (Feb 18th, 2015)

Initial release.
