# frozen_string_literal: true

require "test_helper"

# Frozen contract: "Scope, deletion and lifecycle gates still precede ranking and
# must hold identically on every route — exact, lexical, related, facet,
# aggregate and JOIN."
#
# `Queries::Search::Lexical` says so in a comment and does not do it. Its
# candidate query filters `store_kind` and `project_key` and nothing else, and
# `memory_search_documents` has no lifecycle column to filter on, so a retracted
# statement is retrievable by BM25 exactly as long as its words are a good match.
# That is the one outcome retraction exists to prevent: a record withdrawn as
# wrong is handed back to the model that asked, ranked above the correction.
#
# The fixtures are hostile on purpose. Every ineligible row repeats the query
# term eight times and every eligible row carries it once, so an ungated query
# returns the ineligible row FIRST. A gate that merely reorders would still fail.
#
# `proposed` is eligible. An assistant-authored global record is recorded as
# proposed precisely so it can be reviewed (contract: "assistant-authored global
# records default to proposed and do not become governing user preferences by
# repetition"), and context_search declares lifecycle as both a caller filter and
# a facet dimension — neither means anything if only one value can be returned.
# The gate excludes what has been withdrawn or replaced, not what is unconfirmed.
class LexicalLifecycleGateTest < ActiveSupport::TestCase
  PROJECT = "alpha"
  OUTRANKING_BODY = (["retry"] * 8).join(" ")
  ELIGIBLE_BODY = "the invoice retry lease"

  setup do
    register_project(PROJECT)
  end

  test "should exclude a retracted head revision while returning the active one" do
    # Arrange
    searchable_revision(memory_key: "memory-retracted", lifecycle: "retracted",
                        body: OUTRANKING_BODY)
    searchable_revision(memory_key: "memory-active", lifecycle: "active", body: ELIGIBLE_BODY)

    # Act
    result = lexical_search

    # Assert
    assert_equal ["memory-active"], result.items.map(&:memory_key),
                 "A retracted revision is withdrawn, not merely demoted."
  end

  test "should exclude a superseded head revision while returning the active one" do
    # Arrange — plan 5.4: "An edit immediately makes the previous document row
    # ineligible."
    searchable_revision(memory_key: "memory-superseded", lifecycle: "superseded",
                        body: OUTRANKING_BODY)
    searchable_revision(memory_key: "memory-active", lifecycle: "active", body: ELIGIBLE_BODY)

    # Act
    result = lexical_search

    # Assert
    assert_equal ["memory-active"], result.items.map(&:memory_key)
  end

  test "should still return a proposed revision so an unconfirmed record stays reviewable" do
    # Arrange
    searchable_revision(memory_key: "memory-proposed", lifecycle: "proposed", body: ELIGIBLE_BODY)
    searchable_revision(memory_key: "memory-active", lifecycle: "active", body: ELIGIBLE_BODY)

    # Act
    result = lexical_search

    # Assert — an unconfirmed record is not a withdrawn one; hiding it would make
    # the lifecycle facet and the lifecycle filter unanswerable.
    assert_equal %w[memory-active memory-proposed], result.items.map(&:memory_key).sort
  end

  test "should apply the lifecycle gate inside the candidate query rather than after ranking" do
    # Arrange — one eligible row and a pool of ineligible ones that all outrank
    # it, with a candidate limit smaller than the ineligible set.
    3.times do |index|
      searchable_revision(memory_key: "memory-retracted-#{index}", lifecycle: "retracted",
                          body: OUTRANKING_BODY)
    end
    searchable_revision(memory_key: "memory-active", lifecycle: "active", body: ELIGIBLE_BODY)

    # Act
    result = lexical_search(candidate_limit: 3)

    # Assert — a retracted row must not occupy a candidate slot, or the gate
    # stops being a gate and becomes a way to lose eligible results.
    assert_equal ["memory-active"], result.items.map(&:memory_key)
    assert_equal 1, result.execution[:candidates_considered]
  end

  private

  def lexical_search(candidate_limit: 50, limit: 25, query: "retry")
    Context::Queries::Search::Lexical.new.call(
      scope: Context::Contracts::Scope.new(store: :project, project_key: PROJECT),
      query: query, candidate_limit: candidate_limit, limit: limit
    )
  end

  # A memory whose head revision carries `lifecycle`, projected into the search
  # document that ParadeDB indexes. The projection is defined locally because the
  # shared factory publishes no lifecycle at all — which is the gap under test.
  def searchable_revision(memory_key:, lifecycle:, body:, title: "Invoice retry lease")
    scope_key = register_project(PROJECT)
    event_key = capture_event(project_key: PROJECT)

    ActiveRecord::Base.transaction(requires_new: true) do
      insert_memory_head(memory_key: memory_key, scope_key: scope_key, store_kind: "project",
                         project_key: PROJECT, current_revision: 1)
      insert_revision(memory_key: memory_key, revision: 1, author_event_key: event_key,
                      title: title, body: body, lifecycle: lifecycle)
    end
    insert_row("memory_search_documents",
               memory_key: memory_key, revision: 1, store_kind: "project",
               project_key: PROJECT, title: title, body: body, lifecycle: lifecycle)
    memory_key
  end
end
