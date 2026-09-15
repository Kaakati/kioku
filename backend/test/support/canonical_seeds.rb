# frozen_string_literal: true

# Minimal valid rows for the canonical tables, inserted with raw SQL so that a
# schema test proves what the DATABASE accepts or refuses rather than what an
# Active Record validation happens to do.
#
# Every seed inserts a row that satisfies every constraint these tests assert.
# A seed that fails is a red test, not a skipped one: the arrange step is what
# distinguishes "PostgreSQL refused this violation" from "the table is missing".
require_relative "schema_contract"

module SchemaContract
  CanonicalGraph = Struct.new(
    :installation, :project, :other_project, :session, :agent,
    :global_scope, :project_scope, :other_project_scope, :event,
    keyword_init: true
  )

  module Seeds
    include Helpers

    def seed_installation(installation_key: new_key("installation"))
      insert_row("installations", installation_key: installation_key)
      installation_key
    end

    # `display_name` follows plan 1.2 ("Register a stable project_key, display
    # name, approved repository/root mappings and a stack profile"). `lifecycle`
    # follows plan 5.3 ("Archiving a project preserves its memory but excludes it
    # from active-project selection by default") and needs a default of 'active'
    # so a caller that does not care about archival need not supply it.
    def seed_project(project_key: new_key("project"), display_name: "Kioku",
                     lifecycle: "active")
      insert_row("projects",
                 project_key: project_key,
                 display_name: display_name,
                 lifecycle: lifecycle)
      project_key
    end

    def seed_session(installation_key:, session_key: new_key("session"),
                     provider_session_id: new_key("provider-session"))
      insert_row("sessions",
                 session_key: session_key,
                 installation_key: installation_key,
                 provider_session_id: provider_session_id)
      session_key
    end

    def seed_agent(session_key:, agent_key: new_key("agent"), agent_kind: "main",
                   lineage_state: "root", parent_agent_key: nil, agent_type: nil,
                   identity_source: "hook", provider_agent_id: new_key("provider-agent"))
      insert_row("agents",
                 agent_key: agent_key,
                 session_key: session_key,
                 provider_agent_id: provider_agent_id,
                 agent_kind: agent_kind,
                 agent_type: agent_type,
                 parent_agent_key: parent_agent_key,
                 lineage_state: lineage_state,
                 identity_source: identity_source)
      agent_key
    end

    def seed_scope(installation_key:, scope_kind: "global", project_key: nil,
                   scope_key: new_key("scope"), subject_key: new_key("subject"))
      insert_row("scopes",
                 scope_key: scope_key,
                 installation_key: installation_key,
                 scope_kind: scope_kind,
                 project_key: project_key,
                 subject_key: subject_key)
      scope_key
    end

    def seed_source_object(object_key: new_key("object"), content_hash: new_content_hash,
                           hash_algorithm: "sha256", byte_length: 11,
                           availability: "available", stored_at: Time.current)
      insert_row("source_objects",
                 object_key: object_key,
                 content_hash: content_hash,
                 hash_algorithm: hash_algorithm,
                 byte_length: byte_length,
                 availability: availability,
                 stored_at: stored_at)
      object_key
    end

    def seed_event(installation_key:, event_key: new_key("event"), store_kind: "global",
                   project_key: nil, producer_key: "host-spool",
                   producer_epoch: new_key("epoch"), producer_sequence: 0,
                   session_key: nil, agent_key: nil, attribution_state: "not_applicable",
                   event_type: "user_prompt_submitted", origin_role: "user",
                   tool_use_id: nil, payload_object_key: nil,
                   observed_at: Time.current, recorded_at: Time.current)
      insert_row("events",
                 event_key: event_key, installation_key: installation_key,
                 store_kind: store_kind, project_key: project_key,
                 producer_key: producer_key, producer_epoch: producer_epoch,
                 producer_sequence: producer_sequence, session_key: session_key,
                 agent_key: agent_key, attribution_state: attribution_state,
                 event_type: event_type, origin_role: origin_role,
                 tool_use_id: tool_use_id, payload_object_key: payload_object_key,
                 observed_at: observed_at, recorded_at: recorded_at)
      event_key
    end

    def seed_evidence(scope_key:, evidence_key: new_key("evidence"),
                      evidence_kind: "transcript_excerpt", origin_event_key: nil,
                      object_key: nil, source_anchor: SchemaContract::SOURCE_ANCHOR)
      insert_row("evidence",
                 evidence_key: evidence_key,
                 scope_key: scope_key,
                 evidence_kind: evidence_kind,
                 origin_event_key: origin_event_key,
                 object_key: object_key,
                 source_anchor: source_anchor)
      evidence_key
    end

    # Appendix A: "Insert the memory head and its initial revision in one
    # transaction; the deferred composite foreign key prevents a committed head
    # from pointing to a nonexistent revision."
    def seed_memory_with_head(scope_key:, author_event_key:, store_kind: "project",
                              project_key: nil, memory_key: new_key("memory"),
                              revision: 1, title: "Head revision")
      ActiveRecord::Base.transaction(requires_new: true) do
        insert_memory_head(memory_key: memory_key, scope_key: scope_key,
                           store_kind: store_kind, project_key: project_key,
                           current_revision: revision)
        insert_revision(memory_key: memory_key, revision: revision,
                        author_event_key: author_event_key, title: title)
      end
      memory_key
    end

    def insert_memory_head(memory_key:, scope_key:, store_kind:, project_key:,
                           current_revision:, origin_project_key: nil, category: :infer)
      category = default_category_for(store_kind) if category == :infer
      insert_row("memories",
                 memory_key: memory_key,
                 scope_key: scope_key,
                 store_kind: store_kind,
                 project_key: project_key,
                 origin_project_key: origin_project_key,
                 category: category,
                 current_revision: current_revision)
      memory_key
    end

    def insert_revision(memory_key:, revision:, author_event_key:, title: "Revision",
                        body: "Recorded body.", kind: "decision", lifecycle: "active",
                        authority: "user", author_agent_key: nil,
                        valid_from: Time.current, valid_until: nil,
                        recorded_at: Time.current)
      insert_row("memory_revisions",
                 memory_key: memory_key, revision: revision, kind: kind,
                 title: title, body: body, lifecycle: lifecycle, authority: authority,
                 author_event_key: author_event_key, author_agent_key: author_agent_key,
                 valid_from: valid_from, valid_until: valid_until,
                 recorded_at: recorded_at)
    end

    def insert_memory_evidence(memory_key:, revision:, evidence_key:, relation: "supports")
      insert_row("memory_evidence",
                 memory_key: memory_key, revision: revision,
                 evidence_key: evidence_key, relation: relation)
    end

    def insert_feedback(memory_key:, revision:, author_event_key:,
                        feedback_key: new_key("feedback"), action: "dispute",
                        reason: "Contradicted by a later run.", disposition: "open")
      insert_row("feedback",
                 feedback_key: feedback_key, memory_key: memory_key, revision: revision,
                 author_event_key: author_event_key, action: action,
                 reason: reason, disposition: disposition)
      feedback_key
    end

    # The smallest graph that satisfies every not-null foreign key the memory
    # and evidence tables declare.
    def seed_canonical_graph
      installation = seed_installation
      project = seed_project
      other_project = seed_project(display_name: "Other")
      session = seed_session(installation_key: installation)
      agent = seed_agent(session_key: session)
      SchemaContract::CanonicalGraph.new(
        installation: installation, project: project, other_project: other_project,
        session: session, agent: agent,
        global_scope: seed_scope(installation_key: installation, scope_kind: "global",
                                 subject_key: installation),
        project_scope: seed_scope(installation_key: installation, scope_kind: "project",
                                  project_key: project, subject_key: project),
        other_project_scope: seed_scope(installation_key: installation, scope_kind: "project",
                                        project_key: other_project, subject_key: other_project),
        event: seed_event(installation_key: installation, session_key: session,
                          agent_key: agent, attribution_state: "resolved",
                          origin_role: "assistant")
      )
    end

    private

    # A global engineering record carries one of the four categories of plan 1.3;
    # a project-owned record carries none.
    def default_category_for(store_kind)
      store_kind == "global" ? "engineering_decision" : nil
    end
  end
end
