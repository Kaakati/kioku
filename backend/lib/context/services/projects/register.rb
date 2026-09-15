# frozen_string_literal: true

require "securerandom"
require "time"

module Context
  module Services
    module Projects
      # Registers a project and its approved roots (Plan §1.2).
      #
      # A project's identity is its stable key. Re-registering the same key
      # renames or re-roots the existing project rather than creating a second
      # one, so renaming or moving a project keeps its memories. The
      # configuration revision is checked exactly like a memory head: a stale
      # writer fails and nothing is written.
      #
      # Approving roots advances the project's policy generation, because the
      # set of global guidance that matches the project's stack can change with
      # it and delivery caches keyed on that generation must be invalidated.
      class Register
        def initialize(policy: Domain::Projects::RegistrationPolicy.new,
                       authorization: Queries::ScopeAuthorization.new,
                       receipts: Queries::Idempotency::FindReceipt.new,
                       generations: Queries::Generations.new,
                       records: Storage::Records)
          @policy = policy
          @authorization = authorization
          @receipts = receipts
          @generations = generations
          @records = records
        end

        def call(payload:, actor:, host_link_state: "disconnected", now: Time.now.utc)
          request = Contracts::ProjectRegistration.parse(payload, started_at: now)
          request.envelope.deadline.ensure!(now)
          authorization.call(actor: actor, scope: request.envelope.scope)
          prior = find_receipt(request, actor)
          return replayed(request, prior, actor, host_link_state, now) if prior

          decision = policy.call(registration: request, existing_roots: existing_roots)
          committed = records.base.transaction { write(request, decision, actor, now) }
          registered(request, decision, committed, actor, host_link_state, now)
        end

        private

        attr_reader :policy, :authorization, :receipts, :generations, :records

        def find_receipt(request, actor)
          receipts.call(principal_id: actor.principal_id,
                        idempotency_key: request.envelope.idempotency_key,
                        request_digest: request.envelope.request_digest)
        end

        # Every approved root in the installation, so the policy can refuse one
        # that another project already owns.
        def existing_roots
          records.project_root.all.map do |root|
            { "project_key" => root.project_key, "root_path" => root.root_path }
          end
        end

        def write(request, decision, actor, now)
          records.assert_in_transaction!("project_register")
          project = lock_project(request.project_key)
          # The same append-only revision rule memories use: a configuration
          # revision is a head, and a stale expected revision conflicts.
          revision = Domain::Memories::RevisionPolicy.next_revision(
            head_revision: project&.configuration_revision,
            expected_revision: request.envelope.expected_revision, target_key: request.project_key
          )
          upsert_project(project, request, revision, now)
          replace_roots(request, decision, now)
          bump_policy_generation(request.project_key)
          { revision: revision, receipt_id: write_receipt(request, actor, now), outbox_event_id: write_outbox(request, revision, now) }
        end

        def lock_project(project_key)
          records.project.lock("FOR UPDATE").find_by(project_key: project_key)
        end

        def upsert_project(project, request, revision, now)
          attributes = {
            display_name: request.display_name, stack_profile: request.stack_profile,
            lifecycle: request.lifecycle, descriptor: request.descriptor,
            configuration_revision: revision, updated_at: now
          }
          return project.update!(**attributes) if project

          records.project.create!(project_key: request.project_key, created_at: now, **attributes)
        end

        # Roots are replaced as a set within this transaction, so a removed root
        # stops authorizing immediately rather than lingering.
        def replace_roots(request, decision, now)
          records.project_root.where(project_key: request.project_key).delete_all
          decision.roots.each do |root|
            records.project_root.create!(project_key: request.project_key, kind: root["kind"],
                                         repository_key: root["repository_key"], worktree_key: root["worktree_key"],
                                         root_path: root["root_path"], created_at: now)
          end
        end

        def bump_policy_generation(project_key)
          counter = records.generation_counter.lock("FOR UPDATE")
                           .find_or_initialize_by(subject_key: project_key, counter_kind: "policy")
          counter.value = counter.value.to_i + 1
          counter.save!
        end

        def write_receipt(request, actor, now)
          receipt_id = SecureRandom.uuid_v7
          records.idempotency_receipt.create!(
            receipt_id: receipt_id, actor_principal_id: actor.principal_id,
            idempotency_key: request.envelope.idempotency_key,
            request_digest: request.envelope.request_digest,
            request_id: request.envelope.request_id, committed_at: now
          )
          receipt_id
        end

        def write_outbox(request, revision, now)
          event_id = SecureRandom.uuid_v7
          records.outbox_event.create!(
            event_id: event_id, event_type: "project.registered", store_kind: "project",
            project_key: request.project_key, aggregate_key: request.project_key,
            aggregate_revision: revision,
            payload: { "project_key" => request.project_key, "configuration_revision" => revision },
            state: "pending", attempts: 0, available_at: now, created_at: now
          )
          event_id
        end

        def registered(request, decision, committed, actor, host_link_state, now)
          data = {
            "project_key" => request.project_key, "display_name" => request.display_name,
            "configuration_revision" => committed[:revision], "lifecycle" => request.lifecycle,
            "roots" => decision.roots, "stack_profile" => request.stack_profile,
            "descriptor_matches" => decision.descriptor_matches,
            "outbox_event_id" => committed[:outbox_event_id], "saved" => true
          }
          result(request, actor, host_link_state, now, data: data, warnings: decision.warnings,
                 receipt: { "receipt_id" => committed[:receipt_id], "idempotency_key" => request.envelope.idempotency_key,
                            "request_digest" => request.envelope.request_digest,
                            "committed_at" => now.utc.iso8601(3), "replayed" => false })
        end

        def replayed(request, receipt, actor, host_link_state, now)
          result(request, actor, host_link_state, now, data: receipt.payload, warnings: [],
                 receipt: receipt.to_wire(replayed: true))
        end

        def result(request, actor, host_link_state, now, data:, warnings:, receipt:)
          Serialization::Result.success(
            request_id: request.envelope.request_id, deadline: request.envelope.deadline,
            generation_vector: generations.call(installation_id: actor.installation_id,
                                                project_key: request.project_key,
                                                host_link_state: host_link_state, now: now),
            coverage: Serialization::Coverage.complete(
              declared_input_set: { "project_key" => request.project_key, "roots" => request.roots.length },
              considered: request.roots.length, returned: request.roots.length
            ),
            data: data, receipt: receipt, warnings: warnings, returned: 1, now: now
          )
        end
      end
    end
  end
end
