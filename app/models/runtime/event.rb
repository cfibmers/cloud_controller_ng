module VCAP::CloudController
  class Event < Sequel::Model
    class EventValidationError < StandardError; end
    plugin :serialization

    many_to_one :space, primary_key: :guid, key: :space_guid, without_guid_generation: true

    def validate
      validates_presence :type
      validates_presence :timestamp
      validates_presence :actor
      validates_presence :actor_type
      validates_presence :actee
      validates_presence :actee_type
      validates_not_null :actee_name
    end

    serialize_attributes :json, :metadata

    export_attributes :type, :actor, :actor_type, :actor_name, :actee,
      :actee_type, :actee_name, :timestamp, :metadata, :space_guid,
      :organization_guid

    def metadata
      super || {}
    end

    def before_save
      denormalize_space_and_org_guids
      super
    end

    def denormalize_space_and_org_guids
      # If we have both guids, return.
      # If we have a space, get the guids off of it.
      # If we have only an org, get the org guid from it.
      # Raise.
      if (space_guid && organization_guid) || organization_guid
        return
      elsif space
        self.space_guid = space.guid
        self.organization_guid = space.organization.guid
      else
        raise EventValidationError.new('A Space or an organization_guid must be supplied when creating an Event.')
      end
    end

    def self.user_visibility_filter(user)
      Sequel.or([
        [:space, user.audited_spaces_dataset],
        [:space, user.spaces_dataset],
        [:organization_guid, user.audited_organizations_dataset.map(&:guid)]
      ])
    end
  end
end
