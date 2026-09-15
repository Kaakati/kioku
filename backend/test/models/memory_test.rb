# frozen_string_literal: true

require "test_helper"

# The database constraints in test/schema/memory_ownership_exclusivity_test.rb
# are the guarantee. These tests are about what the API boundary can say when a
# caller gets it wrong: plan 4.1 puts "constraints-facing validations" on the
# model so a bad destination surfaces as kioku.invalid_request rather than as an
# unhandled PG::CheckViolation, which would be rendered as kioku.internal_error
# and would imply "no partial write" without the service having decided that.
class MemoryTest < ActiveSupport::TestCase
  setup do
    assert_canonical_schema_present
    @graph = seed_canonical_graph
  end

  test "should refuse to save a global memory that names an owner project" do
    # Arrange
    memory = Memory.new(memory_key: new_key("memory"), scope_key: @graph.global_scope,
                        store_kind: "global", project_key: @graph.project,
                        category: "engineering_decision", current_revision: 1)

    # Act
    saved = memory.save

    # Assert
    refute saved, "A global record with an owner project must fail validation, not reach PostgreSQL."
    assert_equal 0, row_count("memories", ActiveRecord::Base.sanitize_sql_array(
      ["memory_key = ?", memory.memory_key]
    ))
  end

  test "should refuse to save a project memory that names no owner project" do
    # Arrange — plan 5.2: "never interpret a missing project ID as permission to
    # fall back to global."
    memory = Memory.new(memory_key: new_key("memory"), scope_key: @graph.project_scope,
                        store_kind: "project", project_key: nil, current_revision: 1)

    # Act
    saved = memory.save

    # Assert
    refute saved, "A project record with no owner project must fail validation."
    assert_equal 0, row_count("memories", ActiveRecord::Base.sanitize_sql_array(
      ["memory_key = ?", memory.memory_key]
    ))
  end

  test "should resolve the head to the revision named by current_revision rather than the newest one" do
    # Arrange — three revisions exist; the head names the middle one, which is
    # what a retraction of the newest leaves behind. Appendix A's delivery query
    # joins on r.revision = m.current_revision, never on MAX(revision).
    memory_key = seed_memory_with_head(scope_key: @graph.project_scope, store_kind: "project",
                                       project_key: @graph.project,
                                       author_event_key: @graph.event, title: "First")
    insert_revision(memory_key: memory_key, revision: 2, author_event_key: @graph.event,
                    title: "Second")
    insert_revision(memory_key: memory_key, revision: 3, author_event_key: @graph.event,
                    title: "Third", lifecycle: "retracted")
    execute(ActiveRecord::Base.sanitize_sql_array(
              ["UPDATE memories SET current_revision = 2 WHERE memory_key = ?", memory_key]
            ))

    # Act
    head = Memory.find(memory_key).head_revision

    # Assert
    assert_equal "Second", head.title
    assert_equal 2, head.revision
  end

  test "should keep all appended revisions reachable from the memory so history is not rewritten" do
    # Arrange
    memory_key = seed_memory_with_head(scope_key: @graph.project_scope, store_kind: "project",
                                       project_key: @graph.project,
                                       author_event_key: @graph.event, title: "First")
    insert_revision(memory_key: memory_key, revision: 2, author_event_key: @graph.event,
                    title: "Second")

    # Act
    titles = Memory.find(memory_key).revisions.order(:revision).pluck(:title)

    # Assert — plan invariant 4: corrections append, they do not replace.
    assert_equal %w[First Second], titles
  end

  test "should exclude a global record derived from a project from that project's owned memories" do
    # Arrange — plan 5.2: "Origin project is separate nullable provenance
    # metadata for global records." A project's own memories are the ones it
    # OWNS; treating provenance as ownership would let deleting a project take
    # an independent global preference with it (plan 5.3).
    owned = seed_memory_with_head(scope_key: @graph.project_scope, store_kind: "project",
                                  project_key: @graph.project, author_event_key: @graph.event)
    derived_global = new_key("memory")
    insert_memory_head(memory_key: derived_global, scope_key: @graph.global_scope,
                       store_kind: "global", project_key: nil,
                       origin_project_key: @graph.project, current_revision: 1)
    insert_revision(memory_key: derived_global, revision: 1, author_event_key: @graph.event)
    seed_memory_with_head(scope_key: @graph.other_project_scope, store_kind: "project",
                          project_key: @graph.other_project, author_event_key: @graph.event)

    # Act
    keys = Project.find(@graph.project).memories.pluck(:memory_key)

    # Assert
    assert_equal [owned], keys
  end
end
