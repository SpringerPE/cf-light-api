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
