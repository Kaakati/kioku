# frozen_string_literal: true

module Context
  module Domain
    module Memories
      # Derives the authority label of a write and refuses authority it was not
      # given.
      #
      # Authority is never accepted from the caller: it comes from the
      # authenticated transport principal's origin role, and imported transport
      # pins it to `imported` regardless of what the payload claims, because
      # imported text is evidence data and cannot grant authority (Plan §6.3).
      module AuthorityPolicy
        module_function

        def derive(actor:)
          return "imported" if actor.transport == "imported"

          actor.origin_role
        end

        # Assistant-authored global records default to proposed. They do not
        # become governing user preferences because several agents repeat them,
        # so a non-user actor asking for `active` on a global record is refused
        # rather than quietly downgraded: the caller should know its record was
        # not made policy.
        def resolve_lifecycle(authority:, destination:, requested: nil)
          return requested || "active" unless destination.global?
          return requested || "active" if AuthorityRank.governing?(authority)
          return "proposed" if requested.nil? || requested == "proposed"

          raise Errors::AuthorityViolation.new(
            details: { attempted: "lifecycle=#{requested}", required_authority: AuthorityRank::GOVERNING, actor_authority: authority }
          )
        end

        # Only a user can label a global rule mandatory.
        def check_mandatory!(mandatory:, authority:)
          return false unless mandatory
          return true if AuthorityRank.governing?(authority)

          raise Errors::AuthorityViolation.new(
            details: { attempted: "mandatory", required_authority: AuthorityRank::GOVERNING, actor_authority: authority }
          )
        end

        # A project exception may not defeat a higher authority, and relaxing a
        # mandatory global rule requires the authority to amend that rule.
        def check_override!(actor_authority:, target_authority:, target_mandatory:)
          if target_mandatory && !AuthorityRank.governing?(actor_authority)
            raise Errors::AuthorityViolation.new(
              details: { attempted: "override_mandatory_global", required_authority: AuthorityRank::GOVERNING,
                         actor_authority: actor_authority }
            )
          end
          return true if AuthorityRank.at_least?(actor_authority, target_authority)

          raise Errors::AuthorityViolation.new(
            details: { attempted: "override_higher_authority", required_authority: target_authority,
                       actor_authority: actor_authority }
          )
        end
      end
    end
  end
end
