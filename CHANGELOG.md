## 1.6.6 (Feb 4, 2016)

Features:

  - Now includes the `last_uploaded` time when formatting app data, which shows when an app was last pushed.

## 1.6.5 (Jan 8, 2016)

Features:

  - Made the data age validity configurable by setting the `DATA_AGE_VALIDITY` environment variable. It defaults to 10 minutes.
  - Moved the functionality of the `/internal/status` into `/v1/last_updated` and removed the endpoint.

## 1.6.4 (Jan 5, 2015)

Features:

  - Implement a /internal/status that returns a 503 if the data is older than 5 minutes, 200 otherwise.

## 1.6.3 (Dec 23, 2015)

Features:

  - Use threads instead of processes to lower the memory consumption.

## 1.6.2 (Dec 8, 2015)

Bugfixes:

  - Ensure the worker exits with failure unless all required environment variables are set.

## 1.6.1 (Dec 8, 2015)

Featues:

- Included `memory_quota` and `disk_quota` to the metrics being sent to Graphite.

## 1.6.0 (Dec 4, 2015)

Features:

  - Added support to send app instance stats data (cpu, memory and disk) to Graphite.

## 1.5.0 (Nov 9, 2015)

Features:

  - Retrieves the buildpack when formatting app data, where available.

## 1.4.0 (Nov 7, 2015)

Features:

  - Implemented new endpoint `/v1/last_updated` which shows the last time the data was updated by the worker.
  - Made the update interval and update timeout configurable.

Bugfixes:

  - Fixed an issue where the worker lock was not released when reaching the update timeout.

## 1.3.5 (Nov 6, 2015)

Bugfixes:

  - The default number of parallel map processes was being set incorrectly.

## 1.3.4 (Nov 4, 2015)

Features:

  - Sets a key in Redis showing the last update time.

## 1.3.3 (Nov 4, 2015)

Features:

  - Made the number of parallel map processes configurable.

## 1.3.2 (May 27, 2015)

Features:

  - Implemented worker locking via `redlock` gem.
  - Improved worker logging and refactored code for clarity.

Bugfixes:

  - Fixes issue #6 "Occasional 'null' entries in JSON response".

## 1.3.1 (Apr 28, 2015)

Features:

  - The `stack` attribute is now shown for all apps.

## 1.3.0 (Mar 20, 2015)

Features:

  - Implemented filtering by organisation name in the `/v1/apps` endpoint.

## 1.2.1 (Mar 10, 2015)

Bugfixes:

  - Fixed an issue where the scheduled job timeout in the worker did not match the lock expiry.
  - Disabled STDOUT output buffering, which made debugging harder in certain deployment environments.

## 1.2.0 (Mar 9, 2015)

Features:

  - Parallelised the background worker, to speed up metrics gathering. With our test CF org containing around 125 apps, the worker now takes around 30-40 seconds, instead of over 5 minutes to complete.

Bugfixes:

  - Handles `CFoundry::AppNotFound` exceptions, which can occur when an app is terminated whilst we're trying to retrieve it's usage statistics.

## 1.1.1 (Mar 6, 2015)

Features:

  - Logs the duration of the worker update process after each run.

## 1.1.0 (Mar 5, 2015)

Features:

  - Added locking to the worker, to allow multiple instances of `cf_light_api` to run alongside one another, without duplicating work.

## 1.0.0 (Mar 2, 2015)

Features:
  
  - Added new `/v1/orgs` endpoint for listing all Organisations and their quotas.
  - Re-packaged as a Ruby Gem and released on RubyGems.org.
  - More detailed documentation for endpoints.

## Not versioned (Feb 18th, 2015)

Initial release.
