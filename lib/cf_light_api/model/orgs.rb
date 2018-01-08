require 'virtus'
require 'cf_light_api/model/org'
class Orgs
  include Virtus.model

  attribute :total_results, Integer
  attribute :total_pages, Integer
  attribute :prev_url, String
  attribute :next_url, String

  attribute :resources, Array[Org]
end