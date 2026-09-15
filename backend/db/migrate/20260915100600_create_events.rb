# frozen_string_literal: true

# Capture events (Research Appendix A `events`, plus Plan §1.1/§5.2 ownership).
#
# The (installation_id, producer_key, producer_epoch, producer_sequence) unique
# key is the deduplication key that makes host spool replay safe: a replayed
# entry collides instead of producing a second event.
class CreateEvents < ActiveRecord::Migration[8.1]
  def change
    create_events_table
    add_event_indexes
    add_event_foreign_keys
    add_event_constraints
    add_event_ownership_constraints
  end

  private

  def create_events_table
    create_table :events, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      # Covered by the producer deduplication index below.
      t.references :installation, null: false, type: :uuid, foreign_key: true, index: false
      t.string :event_key, null: false
      t.string :store_kind, null: false
      t.string :project_key
      # Provenance only. A global capture may record which project it came from;
      # that never makes the event project-owned.
      t.string :origin_project_key
      t.string :producer_key, null: false
      t.string :producer_epoch, null: false
      t.bigint :producer_sequence, null: false
      t.string :session_key
      t.string :agent_key
      t.string :attribution_state, null: false
      t.string :event_type, null: false
      t.string :origin_role, null: false
      t.string :tool_use_id
      t.string :payload_object_key
      t.jsonb :correlation, null: false, default: {}
      t.column :observed_at, :timestamptz, null: false
      t.column :recorded_at, :timestamptz, null: false, default: -> { "now()" }
    end
  end

  def add_event_indexes
    add_index :events, :event_key, unique: true
    add_index :events, %i[installation_id producer_key producer_epoch producer_sequence],
              unique: true, name: "events_producer_dedup"
    add_index :events, %i[session_key tool_use_id event_type], name: "events_tool_join"
    add_index :events, :agent_key
    add_index :events, :payload_object_key
    add_index :events, :project_key
    add_index :events, :origin_project_key
  end

  def add_event_foreign_keys
    add_foreign_key :events, :sessions, column: :session_key, primary_key: :session_key,
                                        name: "fk_events_session_key"
    add_foreign_key :events, :agents, column: :agent_key, primary_key: :agent_key,
                                      name: "fk_events_agent_key"
    add_foreign_key :events, :source_objects, column: :payload_object_key,
                                              primary_key: :object_key,
                                              name: "fk_events_payload_object_key"
    add_foreign_key :events, :projects, column: :project_key, primary_key: :project_key,
                                        name: "fk_events_project_key"
    add_foreign_key :events, :projects, column: :origin_project_key, primary_key: :project_key,
                                        name: "fk_events_origin_project_key"
  end

  def add_event_constraints
    add_check_constraint :events, "btrim(event_key) <> '' AND btrim(producer_key) <> '' " \
                                  "AND btrim(producer_epoch) <> '' AND btrim(event_type) <> ''",
                         name: "events_keys_present"
    add_check_constraint :events, "producer_sequence >= 0",
                         name: "events_producer_sequence_non_negative"
    add_check_constraint :events,
                         "attribution_state IN ('resolved', 'unresolved', 'not_applicable')",
                         name: "events_attribution_state_valid"
    add_check_constraint :events,
                         "origin_role IN ('user', 'assistant', 'tool', 'system', 'imported')",
                         name: "events_origin_role_valid"
    add_check_constraint :events, "jsonb_typeof(correlation) = 'object'",
                         name: "events_correlation_is_object"

    # Attribution state and agent nullability move together: a resolved event
    # names its agent, and an unresolved one must not borrow somebody else's.
    add_check_constraint :events,
                         "(attribution_state = 'resolved' AND agent_key IS NOT NULL) " \
                         "OR (attribution_state IN ('unresolved', 'not_applicable') AND agent_key IS NULL)",
                         name: "events_attribution_state_matches_agent"
  end

  def add_event_ownership_constraints
    add_check_constraint :events, "store_kind IN ('project', 'global')",
                         name: "events_store_kind_valid"
    add_check_constraint :events,
                         "(store_kind = 'project' AND project_key IS NOT NULL) " \
                         "OR (store_kind = 'global' AND project_key IS NULL)",
                         name: "events_single_ownership_destination"
    add_check_constraint :events, "origin_project_key IS NULL OR store_kind = 'global'",
                         name: "events_origin_project_is_global_provenance"
  end
end
