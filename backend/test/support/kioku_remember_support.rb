# frozen_string_literal: true

module Kioku
  module Test
    # Shared arrangement for the Context::Services::Memories::Remember cases.
    # It is the reference use case of plan 4.1, so its collaborators (object
    # store, outbox) are explicit constructor arguments and every test varies
    # exactly one of them.
    module RememberSupport
      def remember_service(object_store: nil, outbox: nil)
        Context::Services::Memories::Remember.new(
          object_store: object_store || fake_object_store(durable: [Factories::DURABLE_OBJECT_KEY]),
          outbox: outbox || fake_outbox
        )
      end

      def remember_arguments(overrides = {})
        {
          actor: bridge_actor,
          envelope: mutation_envelope,
          kind: :decision,
          destination: { store_kind: :project, project_key: Factories::PRIMARY_PROJECT_KEY },
          title: "Invoice retry fails under concurrent workers",
          body: "Two workers claimed the same invoice lease; the retry double-charged.",
          evidence: [{ ref: { object_key: Factories::DURABLE_OBJECT_KEY }, relation: :supports }]
        }.merge(overrides)
      end

      # The registered project, its scope row and the retained object a normal
      # project-scoped memory write needs in order to reach canonical commit.
      def arrange_project_with_durable_evidence(project_key: Factories::PRIMARY_PROJECT_KEY)
        register_project(project_key)
        create_durable_object
      end
    end
  end
end
