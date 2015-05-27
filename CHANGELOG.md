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
