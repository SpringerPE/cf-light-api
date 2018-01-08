require 'cf_light_api/client/cf_client'
require 'cf_light_api/model/org'

require "webmock/rspec"

RSpec.describe CfClient do
  before(:each) do

    api = "https://api.io"
    username = "admin"
    password = "password"

    stub_request(:get, "#{api}/info").
        with(headers: {'Accept' => 'application/json', 'Accept-Encoding' => 'gzip;q=1.0,deflate;q=0.6,identity;q=0.3', 'Content-Length' => '0', 'User-Agent' => 'Ruby'}).
        to_return(status: 200, body: '{"authorization_endpoint": "https://uaa.io","user": "22a88597-c4a3-4733-ab66-3dd806b399b9"}', headers: {})

    stub_request(:post, "https://uaa.io/oauth/token").
        with(body: "grant_type=password&username=#{username}&password=#{password}",
             headers: {'Accept' => 'application/json;charset=utf-8', 'Accept-Encoding' => 'gzip;q=1.0,deflate;q=0.6,identity;q=0.3', 'Authorization' => 'Basic Y2Y6', 'Content-Length' => '52', 'Content-Type' => 'application/x-www-form-urlencoded;charset=utf-8', 'User-Agent' => 'Ruby'}).
        to_return(status: 200, body: '{"access_token": "token", "token_type": "token_type"}', headers: {'Content-Type' => 'application/json;charset=UTF-8'})

    @client = CfClient.new(api, username, password)
  end

  context "orgs" do
    it "fetches orgs when there is only one page with one org" do
      stub_request(:get, "https://api.io/v2/organizations").
          to_return(status: 200, body: '{
  "total_results": 1,
  "total_pages": 1,
  "prev_url": null,
  "next_url": null,
   "resources": [
      {
         "metadata": {"guid": "asdf"},
         "entity": {"name": "casper"}
      }]}', headers: {})

      expect(@client.orgs.to_a.first().entity.name).to eq("casper")
    end

    it "fetches orgs when there is only one page with two org" do
      stub_request(:get, "https://api.io/v2/organizations").
          to_return(status: 200, body: '{
  "total_results": 2,
  "total_pages": 1,
  "prev_url": null,
  "next_url": null,
   "resources": [
      {"metadata": {}, "entity": {"name": "casper"}},
      {"metadata": {}, "entity": {"name": "oscar"}}
      ]}', headers: {})

      expected = [
          Org.new({"name" => "casper"}),
          Org.new({"name" => "oscar"})
      ]

      orgs = @client.orgs.to_a
      expect(orgs[0].entity.name).to eq("casper")
      expect(orgs[1].entity.name).to eq("oscar")

    end

    it "fetches orgs when there are two pages" do
      stub_request(:get, "https://api.io/v2/organizations").
          to_return(status: 200, body: '{
          "total_results": 2,
          "total_pages": 2,
          "prev_url": null,
          "next_url": "/v2/organizations?order-direction=asc&page=2&results-per-page=50",
           "resources": [
              {"metadata": {}, "entity": {"name": "casper"}}
              ]}', headers: {})

      stub_request(:get, "https://api.io/v2/organizations?order-direction=asc&page=2&results-per-page=50").
          to_return(status: 200, body: '{
          "total_results": 2,
          "total_pages": 2,
          "prev_url": "/v2/organizations?order-direction=asc&page=1&results-per-page=50",
          "next_url": null,
           "resources": [
              {"metadata": {}, "entity": {"name": "oscar"}}
              ]}', headers: {})

      orgs = @client.orgs.to_a
      expect(orgs[0].entity.name).to eq("casper")
      expect(orgs[1].entity.name).to eq("oscar")
    end
  end


end