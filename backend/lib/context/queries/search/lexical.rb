# frozen_string_literal: true

module Context
  module Queries
    module Search
      # ParadeDB BM25 retrieval over the versioned search-document rows
      # (plan 5.4, plan 7.2 step 5).
      #
      # The scope and lifecycle predicates are applied INSIDE the candidate
      # query, before the candidate limit, so an ineligible row cannot crowd
      # eligible ones out of the pool no matter how well it scores. "Scope,
      # deletion and lifecycle gates still precede ranking and must hold
      # identically on every route" (frozen contract); applying the limit first
      # would make that false, and a gate that only reorders is not a gate — a
      # retracted statement demoted is still a retracted statement returned.
      #
      # A BM25 score is a relevance score. It is reported separately and is never
      # claim support (invariant 1).
      class Lexical
        Hit = Struct.new(:memory_key, :revision, :store_kind, :project_key,
                         :title, :bm25_score, :rank, keyword_init: true)
        Result = Struct.new(:items, :execution, keyword_init: true)

        # An allowlist, not a list of exclusions: a lifecycle value a later
        # version adds is not returned until this gate is told it may be, because
        # a retrieval gate that fails open hands back exactly what was withdrawn.
        #
        # `proposed` is eligible. An assistant-authored global record is recorded
        # as proposed precisely so it can be reviewed, and context_search declares
        # lifecycle as both a caller filter and a facet dimension — neither means
        # anything if only one value can ever be returned. The gate excludes what
        # has been withdrawn or replaced, not what is unconfirmed.
        ELIGIBLE_LIFECYCLES = %w[proposed active].freeze

        LIFECYCLE_GATE = "lifecycle IN (#{ELIGIBLE_LIFECYCLES.map { |v| "'#{v}'" }.join(', ')})"

        CANDIDATES = <<~SQL
          SELECT memory_key, revision, store_kind, project_key, title,
                 paradedb.score(id) AS bm25_score
          FROM memory_search_documents
          WHERE #{LIFECYCLE_GATE} AND %<scope>s AND body @@@ ?
          ORDER BY bm25_score DESC, id ASC
          LIMIT ?
        SQL

        def call(scope:, query:, candidate_limit:, limit:)
          candidates = select(scope, query, candidate_limit)
          items = candidates.first(limit).each_with_index.map { |row, index| hit(row, index) }

          Result.new(
            items: items,
            execution: {
              mode: :lexical,
              candidate_limit: candidate_limit,
              candidates_considered: candidates.size,
              returned: items.size
            }
          )
        end

        private

        def select(scope, query, candidate_limit)
          predicate, values = scope_filter(scope)
          statement = format(CANDIDATES, scope: predicate)
          connection.select_all(
            ActiveRecord::Base.sanitize_sql_array([statement, *values, query, candidate_limit])
          ).to_a
        end

        # Plan 1.3: the default posture combines the active project's authorized
        # memories with applicable global records; other projects are excluded.
        def scope_filter(scope)
          project = "(store_kind = 'project' AND project_key = ?)"
          case scope.store
          when :project then [project, [scope.project_key]]
          when :global then ["(store_kind = 'global')", []]
          else ["(store_kind = 'global' OR #{project})", [scope.project_key]]
          end
        end

        def hit(row, index)
          Hit.new(
            memory_key: row["memory_key"], revision: row["revision"],
            store_kind: row["store_kind"], project_key: row["project_key"],
            title: row["title"], bm25_score: row["bm25_score"], rank: index + 1
          )
        end

        def connection
          ActiveRecord::Base.lease_connection
        end
      end
    end
  end
end
