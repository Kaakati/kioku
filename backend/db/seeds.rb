# frozen_string_literal: true

require "digest"

# Phase 1 continuity fixture (CLAUDE.md "first implementation slice", Plan §11).
#
# Two projects with separate local memories plus one shared global coding
# preference, so project isolation and global sharing can be exercised against
# real rows. Every memory is evidence-linked and every write is idempotent, so
# `rails db:seed` can be replayed after a restart without duplicating records.
#
# This file seeds persistence only. Writing memories in production goes through
# Context::Services, which additionally enforces authority, scope authorization,
# idempotency and outbox commit.
module KiokuSeeds
  module_function

  INSTALLATION_KEY = "kioku-local"
  GLOBAL_SCOPE_KEY = "scope-global-engineering"
  PROJECTS = {
    "project-alpha" => { name: "Alpha billing service", stack: { languages: %w[ruby], frameworks: %w[rails] } },
    "project-beta" => { name: "Beta mobile client", stack: { languages: %w[dart], frameworks: %w[flutter] } }
  }.freeze

  def call
    seed_projects
    seed_scopes
    seed_global_preference
    seed_project_memories
  end

  def installation
    @installation ||= Installation.find_or_create_by!(installation_key: INSTALLATION_KEY) do |record|
      record.display_name = "Local Kioku installation"
    end
  end

  def seed_projects
    PROJECTS.each do |project_key, attributes|
      Project.find_or_create_by!(project_key:) do |record|
        record.installation = installation
        record.display_name = attributes[:name]
        record.stack_profile = attributes[:stack]
      end
    end
  end

  def seed_scopes
    Scope.find_or_create_by!(scope_key: GLOBAL_SCOPE_KEY) do |record|
      record.installation = installation
      record.scope_kind = "global"
      record.store_kind = "global"
      record.subject_key = "engineering"
    end

    PROJECTS.each_key { |project_key| project_scope(project_key) }
  end

  def project_scope(project_key)
    Scope.find_or_create_by!(scope_key: "scope-#{project_key}") do |record|
      record.installation = installation
      record.scope_kind = "project"
      record.store_kind = "project"
      record.project_key = project_key
      record.subject_key = project_key
    end
  end

  # The shared preference both projects retrieve. It is user-authored, so it
  # governs; an assistant repeating it would only ever be `proposed`.
  def seed_global_preference
    record_memory(
      memory_key: "global-small-functions",
      scope: Scope.find_by!(scope_key: GLOBAL_SCOPE_KEY),
      category: "coding_style",
      kind: "constraint",
      authority: "user",
      title: "Prefer small functions and descriptive names",
      body: "Keep functions short enough to read in one pass and name them for what they do. " \
            "Applies to every project unless a project records an explicit exception.",
      applicability: { "languages" => [], "frameworks" => [], "platforms" => [],
                       "conditions" => "All projects in this installation." },
      excerpt: "User instruction: keep functions small and names descriptive."
    )
  end

  # Distinct project histories: neither is visible from the other project's scope.
  def seed_project_memories
    record_memory(
      memory_key: "alpha-invoice-retry-attempt",
      scope: project_scope("project-alpha"),
      kind: "attempt",
      authority: "assistant",
      title: "Invoice retry fix failed under concurrent workers",
      body: "Retrying the invoice job on a row lock deadlocked once two workers claimed the " \
            "same invoice. The attempt was rejected; a claim lease is the next thing to try.",
      excerpt: "Worker log: deadlock detected on invoices_pkey during concurrent retry."
    )

    record_memory(
      memory_key: "beta-offline-cache-decision",
      scope: project_scope("project-beta"),
      kind: "decision",
      authority: "user",
      title: "Cache the catalogue offline in the mobile client",
      body: "Beta ships to field devices with intermittent connectivity, so the catalogue is " \
            "cached locally and reconciled on reconnect.",
      excerpt: "User decision recorded during the Beta scoping session."
    )
  end

  # The head and its revision 1 are inserted in one transaction. The deferred
  # foreign key fk_memories_current_revision is what allows the head to be written
  # first while still forbidding a committed head that points at no revision.
  def record_memory(memory_key:, scope:, kind:, authority:, title:, body:, excerpt:,
                    category: nil, applicability: {})
    return if Memory.exists?(memory_key:)

    evidence = record_evidence(memory_key:, scope:, excerpt:)

    ActiveRecord::Base.transaction do
      Memory.create!(memory_key:, scope_key: scope.scope_key, store_kind: scope.store_kind,
                     project_key: scope.project_key, category:, current_revision: 1)
      MemoryRevision.create!(memory_key:, revision: 1, kind:, title:, body:, authority:,
                             lifecycle: "active", applicability:,
                             author_event_key: evidence.origin_event_key,
                             valid_from: Time.current)
      MemoryEvidence.create!(memory_key:, revision: 1, relation: "supports",
                             evidence_key: evidence.evidence_key)
    end
  end

  def record_evidence(memory_key:, scope:, excerpt:)
    object = record_source_object(memory_key:, excerpt:)
    event = record_event(memory_key:, scope:, object:)

    Evidence.find_or_create_by!(evidence_key: "evidence-#{memory_key}") do |record|
      record.scope_key = scope.scope_key
      record.store_kind = scope.store_kind
      record.project_key = scope.project_key
      record.evidence_kind = "captured_statement"
      record.origin_event_key = event.event_key
      record.object_key = object.object_key
      record.source_anchor = { "schema_version" => 1, "kind" => "seed_excerpt",
                               "object_key" => object.object_key }
    end
  end

  # Object bytes are durable before the evidence handle commits (Plan invariant 3).
  # The seed writes only the committed metadata; there is no object file to stage.
  def record_source_object(memory_key:, excerpt:)
    SourceObject.find_or_create_by!(object_key: "object-#{memory_key}") do |record|
      record.content_hash = Digest::SHA256.hexdigest(excerpt)
      record.hash_algorithm = "sha256"
      record.byte_length = excerpt.bytesize
      record.availability = "available"
    end
  end

  # Attribution stays unresolved: the seed has no authenticated agent identity,
  # and inventing one would merge unrelated activity under a false agent.
  def record_event(memory_key:, scope:, object:)
    Event.find_or_create_by!(event_key: "event-#{memory_key}") do |record|
      record.installation = installation
      record.store_kind = scope.store_kind
      record.project_key = scope.project_key
      record.producer_key = "seed"
      record.producer_epoch = "seed-epoch-1"
      record.producer_sequence = next_producer_sequence
      record.attribution_state = "unresolved"
      record.event_type = "memory_seed"
      record.origin_role = "system"
      record.payload_object_key = object.object_key
      record.observed_at = Time.current
    end
  end

  def next_producer_sequence
    @next_producer_sequence = (@next_producer_sequence || last_seeded_sequence) + 1
  end

  def last_seeded_sequence
    Event.where(installation_id: installation.id, producer_key: "seed",
                producer_epoch: "seed-epoch-1").maximum(:producer_sequence) || -1
  end
end

KiokuSeeds.call
