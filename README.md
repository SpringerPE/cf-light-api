# What is this?

A super leightweight api for cloud foundry. Why? Well the CF api
contains all sorts of relations making it very heavy to query.

Having lots of api consumers for random scripts and dashboard makes it neccecary to scale up the CF installation not to disrupt normal "cf cli operations"
So, lets just cash all the data we want in redis for 5 minutes and serve that. Wiie. \o/

When doing a cf push in this repo you will push two apps, one is the
api and the other is the worker app.

## API

The API just reads a stringified JSON from Redis and serves it under
/v1/

Thats it..

## Worker

The worker basically gets all the data we want from the real API every
n mins, puts in Redis and sleeps.

## Deps

    rvm use 2.0.0@cf-light-api --create
    bundle install

# Deploy
    
    cp example-manifest.yml manifest.yml
    emacs manifest.yml # Take that feeble Vi users.
    cf push
