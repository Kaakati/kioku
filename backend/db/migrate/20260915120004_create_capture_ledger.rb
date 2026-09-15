# frozen_string_literal: true

# Retained objects, captured events and the evidence rows that anchor to them
# (research Appendix A; plan 5.2 "Event and evidence"; plan 7.1 capture).
#
# Appendix A's dialect is translated, not copied:
#   * `*_at_ms INTEGER` becomes `timestamptz` (plan 5.1). The host spool and the
#     container do not agree on local time; a naive timestamp loses the offset.
#   * `source_anchor_json TEXT CHECK (json_valid(...))` becomes `source_anchor
#     jsonb` (plan 5.1 "jsonb for bounded structured payloads"); the type is the
#     validity check.
#   * `hash_algorithm` defaults to 'sha256', not Appendix A's 'blake3' (plan 4.2:
#     "Ruby's standard digest support for SHA-256 content addressing").
class CreateCaptureLedger < ActiveRecord::Migration[8.1]
  OBJECT_AVAILABILITY = %w[available purged].freeze
  ATTRIBUTION_STATES = %w[resolved unresolved not_applicable].freeze
  ORIGIN_ROLES = %w[user assistant tool system imported].freeze
  STORE_KINDS = %w[global project].freeze

  def change
    create_source_objects
    create_events
    add_event_check_constraints
    create_evidence
  end

  private

  def create_source_objects
    create_table :source_objects, id: :text, primary_key: :object_key do |t|
      t.text :content_hash, null: false
      t.text :hash_algorithm, null: false, default: "sha256"
      t.bigint :byte_length, null: false
      t.text :availability, null: false
      t.timestamptz :stored_at, null: false
    end

    # Plan 5.3: "Content addressing permits byte deduplication"; two rows for the
    # same bytes would break the reference accounting a purge depends on.
    add_index :source_objects, :content_hash, unique: true
    # The fetch contract reports truncated.total_bytes from this column, so a
    # negative value makes every budget comparison against it wrong.
    add_check_constraint :source_objects, "byte_length >= 0",
                         name: "source_objects_byte_length_non_negative"
    # Physical object-store state only. The per-reference delivery label
    # (available|redacted|missing|expired) is a different field on a different
    # layer; collapsing them would render purged bytes as merely redacted.
    add_check_constraint :source_objects,
                         "availability IN (#{quoted(OBJECT_AVAILABILITY)})",
                         name: "source_objects_availability_vocabulary"
  end

  def create_events
    create_table :events, id: :text, primary_key: :event_key do |t|
      t.text :installation_key, null: false
      t.text :store_kind, null: false
      t.text :project_key
      t.text :producer_key, null: false
      t.text :producer_epoch, null: false
      t.bigint :producer_sequence, null: false
      t.text :session_key
      t.text :agent_key
      t.text :attribution_state, null: false
      t.text :event_type, null: false
      t.text :origin_role, null: false
      t.text :tool_use_id
      t.text :payload_object_key
      t.timestamptz :observed_at, null: false
      t.timestamptz :recorded_at, null: false
    end

    add_event_indexes
    add_event_foreign_keys
  end

  def add_event_indexes
    # Appendix A's deduplication key: what makes host spool replay safe (plan 7.1
    # step 6, "Lost acknowledgments replay safely"). Its leading column also
    # supports the installation_key foreign key.
    add_index :events, %i[installation_key producer_key producer_epoch producer_sequence],
              unique: true, name: "events_producer_sequence_unique"
    # Appendix A's events_tool_join; leading column supports the session_key
    # foreign key.
    add_index :events, %i[session_key tool_use_id event_type], name: "events_tool_join"
    add_index :events, :project_key
    add_index :events, :agent_key
    add_index :events, :payload_object_key
  end

  def add_event_foreign_keys
    add_foreign_key :events, :installations, column: :installation_key,
                                             primary_key: :installation_key
    add_foreign_key :events, :projects, column: :project_key, primary_key: :project_key
    add_foreign_key :events, :sessions, column: :session_key, primary_key: :session_key
    add_foreign_key :events, :agents, column: :agent_key, primary_key: :agent_key
    add_foreign_key :events, :source_objects, column: :payload_object_key,
                                              primary_key: :object_key
  end

  def add_event_check_constraints
    add_check_constraint :events, "store_kind IN (#{quoted(STORE_KINDS)})",
                         name: "events_store_kind_vocabulary"
    add_check_constraint :events, "attribution_state IN (#{quoted(ATTRIBUTION_STATES)})",
                         name: "events_attribution_state_vocabulary"
    # The contract derives the authority label from origin_role; a role outside
    # the five would produce a label with no defined meaning.
    add_check_constraint :events, "origin_role IN (#{quoted(ORIGIN_ROLES)})",
                         name: "events_origin_role_vocabulary"
    add_check_constraint :events, "producer_sequence >= 0",
                         name: "events_producer_sequence_non_negative"
    # Plan 5.2: "Tasks and project events require a project owner." Plan 7.1 step
    # 2: "unresolved project capture cannot be misfiled in the global store."
    add_check_constraint :events, "store_kind <> 'project' OR project_key IS NOT NULL",
                         name: "events_project_store_requires_owner"
    # Research §8: attribution "can remain null until resolved". An event marked
    # resolved with no agent is a claim of established identity that nothing
    # backs — plan invariant 9's false independent confirmation.
    add_check_constraint :events, <<~SQL.squish, name: "events_attribution_matches_agent"
      (attribution_state = 'resolved' AND agent_key IS NOT NULL)
      OR (attribution_state IN ('unresolved', 'not_applicable') AND agent_key IS NULL)
    SQL
  end

  def create_evidence
    create_table :evidence, id: :text, primary_key: :evidence_key do |t|
      t.text :scope_key, null: false
      t.text :evidence_kind, null: false
      t.text :origin_event_key
      t.text :object_key
      t.jsonb :source_anchor, null: false
    end

    add_index :evidence, :scope_key
    add_index :evidence, :origin_event_key
    add_index :evidence, :object_key
    add_foreign_key :evidence, :scopes, column: :scope_key, primary_key: :scope_key
    add_foreign_key :evidence, :events, column: :origin_event_key, primary_key: :event_key
    add_foreign_key :evidence, :source_objects, column: :object_key, primary_key: :object_key

    # Appendix A. An evidence row anchored to neither is a handle to nothing: it
    # would satisfy the contract's "at least one evidence link" count while
    # proving nothing (plan invariant 3).
    add_check_constraint :evidence,
                         "origin_event_key IS NOT NULL OR object_key IS NOT NULL",
                         name: "evidence_requires_an_anchor"
  end

  def quoted(values)
    values.map { |value| "'#{value}'" }.join(", ")
  end
end
