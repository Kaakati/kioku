# frozen_string_literal: true

# Retained object metadata (Research Appendix A `source_objects`, Plan §5.3).
#
# Bytes live in the object directory under KIOKU_OBJECT_ROOT; this table is the
# committed metadata that makes an evidence handle available. Content addressing
# deduplicates bytes, so `content_hash` is unique here — scope and retention live
# on `evidence`, which is why a raw hash never grants access on its own.
class CreateSourceObjects < ActiveRecord::Migration[8.1]
  def change
    create_table :source_objects, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.string :object_key, null: false
      t.string :content_hash, null: false
      t.string :hash_algorithm, null: false, default: "blake3"
      t.bigint :byte_length, null: false
      t.string :availability, null: false, default: "available"
      t.column :stored_at, :timestamptz, null: false, default: -> { "now()" }
      t.column :purged_at, :timestamptz
    end

    add_index :source_objects, :object_key, unique: true
    add_index :source_objects, :content_hash, unique: true

    add_check_constraint :source_objects, "btrim(object_key) <> '' AND btrim(content_hash) <> ''",
                         name: "source_objects_keys_present"
    add_check_constraint :source_objects, "byte_length >= 0",
                         name: "source_objects_byte_length_non_negative"
    add_check_constraint :source_objects, "availability IN ('available', 'purged')",
                         name: "source_objects_availability_valid"
    add_check_constraint :source_objects,
                         "(availability = 'purged' AND purged_at IS NOT NULL) " \
                         "OR (availability = 'available' AND purged_at IS NULL)",
                         name: "source_objects_purged_at_matches_availability"
  end
end
