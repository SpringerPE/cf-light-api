require 'virtus'

module Metadata
  include Virtus.module

  attribute :guid, String
  attribute :url, String
  attribute :created_at, String
  attribute :updated_at, String
end