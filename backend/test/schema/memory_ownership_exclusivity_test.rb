# frozen_string_literal: true

require "test_helper"

# Plan 5.2, verbatim: "Memory ownership requires exactly one destination:
# store_kind='global' with no owner project, or store_kind='project' with a
# non-null project_key. ... never interpret a missing project ID as permission
# to fall back to global."
#
# Plan invariant 11 and 12 and §1.1 are the reason: a record that is both
# project-owned and global leaks one project's private history into every other
# project's retrieval, and a record that is neither is unreachable by any
# authorized scope while still sitting in the table. Rails validations do not
# survive a bulk insert, a replayed spool entry or a migration backfill; the
# CHECK constraint does.
class MemoryOwnershipExclusivityTest < ActiveSupport::TestCase
  setup do
    assert_canonical_schema_present
    @graph = seed_canonical_graph
  end

  test "should reject a memory that is global and also names an owner project" do
    # Arrange / Act / Assert — both set.
    assert_database_rejects(because: [PG::CheckViolation]) do
      insert_memory_head(memory_key: new_key("memory"), scope_key: @graph.global_scope,
                         store_kind: "global", project_key: @graph.project,
                         current_revision: 1)
    end
  end

  test "should reject a memory that is project-owned and names no owner project" do
    # Arrange / Act / Assert — neither set.
    assert_database_rejects(because: [PG::CheckViolation]) do
      insert_memory_head(memory_key: new_key("memory"), scope_key: @graph.project_scope,
                         store_kind: "project", project_key: nil,
                         current_revision: 1)
    end
  end

  test "should accept a global memory that names no owner project" do
    # Arrange
    memory_key = new_key("memory")

    # Act
    insert_memory_head(memory_key: memory_key, scope_key: @graph.global_scope,
                       store_kind: "global", project_key: nil, current_revision: 1)

    # Assert
    assert_equal 1, row_count("memories", ActiveRecord::Base.sanitize_sql_array(
      ["memory_key = ? AND project_key IS NULL", memory_key]
    ))
  end

  test "should accept a project memory that names its owner project" do
    # Arrange
    memory_key = new_key("memory")

    # Act
    insert_memory_head(memory_key: memory_key, scope_key: @graph.project_scope,
                       store_kind: "project", project_key: @graph.project,
                       current_revision: 1)

    # Assert
    assert_equal @graph.project, select_value(ActiveRecord::Base.sanitize_sql_array(
      ["SELECT project_key FROM memories WHERE memory_key = ?", memory_key]
    ))
  end

  test "should accept a global memory that records the project it was derived from" do
    # Arrange — plan 5.2: "Origin project is separate nullable provenance
    # metadata for global records." Plan 1.3's split write keeps the reusable
    # global record linked to its source project without giving that project
    # ownership of it, so the exclusivity CHECK must read project_key only.
    memory_key = new_key("memory")

    # Act
    insert_memory_head(memory_key: memory_key, scope_key: @graph.global_scope,
                       store_kind: "global", project_key: nil,
                       origin_project_key: @graph.project, current_revision: 1)

    # Assert
    assert_equal [nil, @graph.project],
                 select_rows(ActiveRecord::Base.sanitize_sql_array(
                   ["SELECT project_key, origin_project_key FROM memories WHERE memory_key = ?",
                    memory_key]
                 )).first.values_at("project_key", "origin_project_key")
  end

  test "should reject a store_kind outside the project and global destinations" do
    # Arrange / Act / Assert — the discriminator has exactly two values; a third
    # would create a destination with no ownership rule at all.
    assert_database_rejects(because: [PG::CheckViolation]) do
      insert_memory_head(memory_key: new_key("memory"), scope_key: @graph.global_scope,
                         store_kind: "installation", project_key: nil,
                         current_revision: 1, category: nil)
    end
  end

  test "should reject a category outside the four global engineering categories" do
    # Arrange — plan 1.3 fixes the vocabulary: coding_style,
    # engineering_decision, architecture, preferred_library.
    assert_database_rejects(because: [PG::CheckViolation]) do
      insert_memory_head(memory_key: new_key("memory"), scope_key: @graph.global_scope,
                         store_kind: "global", project_key: nil,
                         current_revision: 1, category: "testing_policy")
    end
  end

  test "should reject a memory head whose current_revision is below one" do
    # Arrange — Appendix A: CHECK (current_revision >= 1). Revision zero would
    # make a head that points at nothing look valid to the deferred foreign key
    # only because no such revision can ever exist.
    assert_database_rejects(because: [PG::CheckViolation]) do
      insert_memory_head(memory_key: new_key("memory"), scope_key: @graph.global_scope,
                         store_kind: "global", project_key: nil, current_revision: 0)
    end
  end
end
