# frozen_string_literal: true

require "test_helper"

# Plan 7.2 step 5: "Scope filters apply before candidate limits so unrelated
# projects cannot crowd out eligible results." Plan 1.3: "Other projects'
# memories are excluded by default." Frozen contract: "Scope, deletion and
# lifecycle gates still precede ranking and must hold identically on every
# route."
#
# The fixture is deliberately hostile: every out-of-scope row outranks every
# eligible row on BM25 term frequency, and there are more of them than the
# candidate pool holds. If the limit were applied before the scope filter the
# eligible rows could not survive it.
class LexicalScopeOrderingTest < ActiveSupport::TestCase
  CANDIDATE_LIMIT = 40
  CROWDING_ROWS = 45

  setup do
    register_project("alpha")
    register_project("beta")
  end

  test "should return every eligible in scope row when out of scope rows outnumber the candidate limit" do
    crowding_keys = Array.new(CROWDING_ROWS) do |index|
      create_searchable_memory(memory_key: "beta-#{index}", project_key: "beta",
                               body: (["retry"] * 8).join(" "))
    end
    eligible_keys = Array.new(5) do |index|
      create_searchable_memory(memory_key: "alpha-#{index}", project_key: "alpha",
                               body: "the invoice retry lease")
    end

    result = lexical_search(scope: scope_for(store: :project), candidate_limit: CANDIDATE_LIMIT, limit: 25)

    assert_equal eligible_keys.sort, result.items.map(&:memory_key).sort
    assert_empty result.items.map(&:memory_key) & crowding_keys
  end

  test "should report a candidate pool no larger than the requested candidate limit when scope is applied first" do
    Array.new(CROWDING_ROWS) do |index|
      create_searchable_memory(memory_key: "beta-#{index}", project_key: "beta",
                               body: (["retry"] * 8).join(" "))
    end
    Array.new(5) do |index|
      create_searchable_memory(memory_key: "alpha-#{index}", project_key: "alpha",
                               body: "the invoice retry lease")
    end

    result = lexical_search(scope: scope_for(store: :project), candidate_limit: CANDIDATE_LIMIT, limit: 25)

    assert_equal CANDIDATE_LIMIT, result.execution[:candidate_limit]
    assert_operator result.execution[:candidates_considered], :<=, CANDIDATE_LIMIT
    assert_equal 5, result.execution[:returned]
  end

  test "should combine the active project with applicable global records and still exclude another project" do
    alpha_keys = Array.new(3) do |index|
      create_searchable_memory(memory_key: "alpha-#{index}", project_key: "alpha", body: "retry policy")
    end
    beta_keys = Array.new(3) do |index|
      create_searchable_memory(memory_key: "beta-#{index}", project_key: "beta",
                               body: (["retry"] * 8).join(" "))
    end
    global_keys = Array.new(2) do |index|
      create_searchable_memory(memory_key: "global-#{index}", project_key: nil, store_kind: "global",
                               category: "engineering_decision", body: "retry policy for concurrent writers")
    end

    result = lexical_search(scope: scope_for(store: :both), candidate_limit: 200, limit: 50)

    assert_equal (alpha_keys + global_keys).sort, result.items.map(&:memory_key).sort
    assert_empty result.items.map(&:memory_key) & beta_keys
  end

  private

  def lexical_search(scope:, candidate_limit:, limit:, query: "retry")
    Context::Queries::Search::Lexical.new.call(
      scope: scope, query: query, candidate_limit: candidate_limit, limit: limit
    )
  end

  def scope_for(store:, project_key: "alpha")
    Context::Contracts::Scope.new(store: store, project_key: project_key)
  end
end
