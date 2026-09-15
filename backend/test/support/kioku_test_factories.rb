# frozen_string_literal: true

require_relative "canonical_seeds"

module Kioku
  module Test
    # Arrangement and read-back for the service and API suites.
    #
    # Writes go through SchemaContract::Seeds so there is exactly one description
    # of the canonical schema in the test tree; reads use the storage column names
    # that suite pins down (`memories.current_revision`,
    # `memory_revisions.author_event_key`). `head_revision` stays a wire name on
    # the service result, which is the mapping plan 5.2 asks to be written down.
    #
    # Constants are resolved inside method bodies on purpose: during the red phase
    # none of them exist yet, and a reference at load time would abort the runner
    # instead of failing the individual test that depends on it.
    module Factories
      include SchemaContract::Seeds

      DURABLE_OBJECT_KEY = "object-durable-1"
      MISSING_OBJECT_KEY = "object-never-uploaded"
      PRIMARY_PROJECT_KEY = "alpha"
      OTHER_PROJECT_KEY = "beta"

      # --- envelope and actor values (service layer) ---------------------------

      def request_digest_for(seed)
        "sha256:#{Digest::SHA256.hexdigest(seed.to_s)}"
      end

      def bridge_actor(origin_role: :user, principal_id: "kioku.host_bridge")
        Context::Domain::Actor.new(
          principal_id: principal_id,
          origin_role: origin_role,
          installation_key: installation_key,
          identity_source: :transport,
          attribution_state: :resolved
        )
      end

      def project_scope(project_key: PRIMARY_PROJECT_KEY, store: :project)
        Context::Contracts::Scope.new(store: store, project_key: project_key)
      end

      def mutation_envelope(project_key: PRIMARY_PROJECT_KEY, idempotency_key: "idem-1",
                            request_digest: nil, expected_revision: nil, deadline_ms: 5000)
        Context::Contracts::Envelope.new(
          schema_version: "kioku.tool.v1",
          request_id: SecureRandom.uuid,
          deadline_ms: deadline_ms,
          scope: project_scope(project_key: project_key),
          idempotency_key: idempotency_key,
          request_digest: request_digest || request_digest_for(idempotency_key),
          expected_revision: expected_revision
        )
      end

      # --- wire envelopes (API boundary) --------------------------------------

      def wire_envelope(overrides = {})
        {
          "schema_version" => "kioku.tool.v1",
          "request_id" => SecureRandom.uuid,
          "deadline_ms" => 5000,
          "scope" => { "store" => "project", "project_key" => PRIMARY_PROJECT_KEY },
          "idempotency_key" => "idem-#{SecureRandom.hex(4)}",
          "request_digest" => request_digest_for("probe"),
          "expected_revision" => nil
        }.merge(overrides.transform_keys(&:to_s))
      end

      def wire_read_envelope(overrides = {})
        wire_envelope(overrides).except("idempotency_key", "request_digest", "expected_revision")
      end

      # --- canonical arrangement ----------------------------------------------

      def installation_key
        @installation_key ||= seed_installation
      end

      def global_scope_key
        @global_scope_key ||= seed_scope(installation_key: installation_key,
                                         scope_kind: "global", subject_key: installation_key)
      end

      # Registers a project and its scope row once per test, and returns the
      # scope key every project-owned row has to hang from.
      def register_project(project_key)
        @project_scope_keys ||= {}
        @project_scope_keys[project_key] ||= begin
          seed_project(project_key: project_key, display_name: project_key.to_s.capitalize)
          seed_scope(installation_key: installation_key, scope_kind: "project",
                     project_key: project_key, subject_key: project_key)
        end
      end

      def scope_key_for(store_kind, project_key)
        store_kind.to_s == "global" ? global_scope_key : register_project(project_key)
      end

      # memory_revisions.author_event_key is NOT NULL: a revision is always
      # attributed to the capture event it came from (Appendix A, plan 7.1).
      def capture_event(project_key: PRIMARY_PROJECT_KEY, origin_role: "user")
        store_kind = project_key.nil? ? "global" : "project"
        register_project(project_key) unless project_key.nil?
        seed_event(installation_key: installation_key, store_kind: store_kind,
                   project_key: project_key, origin_role: origin_role)
      end

      def create_durable_object(object_key: DURABLE_OBJECT_KEY)
        seed_source_object(object_key: object_key,
                           content_hash: "sha256:#{Digest::SHA256.hexdigest(object_key)}")
      end

      def create_evidence(evidence_key: "evidence-1", project_key: PRIMARY_PROJECT_KEY,
                          object_key: DURABLE_OBJECT_KEY)
        seed_evidence(scope_key: register_project(project_key),
                      evidence_key: evidence_key,
                      object_key: object_key)
      end

      def create_memory(memory_key:, project_key: PRIMARY_PROJECT_KEY, store_kind: "project",
                        revisions: 1, kind: "decision", authority: "user",
                        title: "Recorded decision", body: "Recorded body", category: :infer)
        scope_key = scope_key_for(store_kind, project_key)
        event_key = capture_event(project_key: store_kind == "global" ? nil : project_key)

        ActiveRecord::Base.transaction(requires_new: true) do
          insert_memory_head(memory_key: memory_key, scope_key: scope_key, store_kind: store_kind,
                             project_key: store_kind == "global" ? nil : project_key,
                             current_revision: revisions, category: category)
          (1..revisions).each do |revision|
            insert_revision(memory_key: memory_key, revision: revision, author_event_key: event_key,
                            title: "#{title} #{revision}", body: "#{body} #{revision}",
                            kind: kind, authority: authority)
          end
        end
        memory_key
      end

      # A memory plus the versioned search document ParadeDB indexes; that derived
      # row is what the lexical query reads (plan 5.4, 7.1 step 5).
      def create_searchable_memory(memory_key:, project_key:, body:, store_kind: "project",
                                   title: "Searchable memory", category: :infer)
        create_memory(memory_key: memory_key, project_key: project_key, store_kind: store_kind,
                      title: title, body: body, category: category)
        insert_row("memory_search_documents",
                   memory_key: memory_key, revision: 1, store_kind: store_kind,
                   project_key: store_kind == "global" ? nil : project_key,
                   title: title, body: body)
        memory_key
      end

      # --- read-back -----------------------------------------------------------

      def revisions_for(memory_key)
        MemoryRevision.where(memory_key: memory_key).order(:revision)
      end

      def memory_record(memory_key)
        Memory.find_by(memory_key: memory_key)
      end

      def memory_revision_count
        row_count("memory_revisions", "TRUE")
      end

      def memory_count(store_kind: nil)
        store_kind ? row_count("memories", "store_kind = '#{store_kind}'") : row_count("memories", "TRUE")
      end

      def evidence_relations_for(memory_key:, revision:)
        select_rows(ActiveRecord::Base.sanitize_sql_array(
                      ["SELECT evidence_key, relation FROM memory_evidence WHERE memory_key = ? AND revision = ?",
                       memory_key, revision]
                    ))
      end

      def receipt_count(idempotency_key)
        row_count("idempotency_receipts",
                  ActiveRecord::Base.sanitize_sql_array(["idempotency_key = ?", idempotency_key]))
      end

      def search_document_count
        row_count("memory_search_documents", "TRUE")
      end
    end
  end
end
