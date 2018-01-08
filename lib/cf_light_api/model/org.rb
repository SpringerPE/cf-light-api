require 'virtus'
require 'cf_light_api/model/metadata'


class OrgEntity
  include Virtus.model

  attribute :name, String
end

class Org
  include Virtus.model

  attribute :entity, OrgEntity
end




