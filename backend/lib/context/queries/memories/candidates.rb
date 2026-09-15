# frozen_string_literal: true

require "time"

module Context
  module Queries
    module Memories
      # Scope-aware candidate selection over current memory revisions.
      #
      # The order of operations is the point. Scope narrows first, then the
      # lifecycle, validity and deletion gates, then the dispute policy, and
      # only then ordering and the candidate limit. Every gate holds identically
      # here and on every later route; ranking never runs before them.
      #
      # The dispute rule is the one from Research Appendix A: an open dispute
      # suppresses automatic confident delivery of a factual assertion, but a
      # governing user decision, constraint or correction is still returned so
      # the objection can be rendered alongside it.
      class Candidates
        GOVERNING_KINDS = %w[decision constraint correction].freeze
        DEFAULT_CANDIDATE_LIMIT = 40
        RANKING_CONFIG_VERSION = "kioku.ranking.v1-recency-tiebreak-memory-key"

        Page = Data.define(:items, :considered, :continuation, :truncated)

        def initialize(records: Storage::Records, scope_filter: ScopeFilter.new)
          @records = records
          @scope_filter = scope_filter
        end

        def call(authorized_scope:, coverage:, filters: {}, candidate_limit: DEFAULT_CANDIDATE_LIMIT,
                 include_disputed: false, now: Time.now.utc, cursor: nil, generation_vector: nil)
          relation = gated(scope_filter.call(relation: base_relation, authorized_scope: authorized_scope), filters, now)
          relation = suppress_disputed(relation) unless include_disputed
          relation = seek(relation, cursor, authorized_scope, filters, generation_vector)
          rows = relation.order(recorded_at: :desc, memory_key: :asc).limit(candidate_limit + 1).to_a
          build_page(rows, candidate_limit, coverage, authorized_scope, filters, generation_vector, now)
        end

        private

        attr_reader :records, :scope_filter

        def base_relation
          records.memory_search_document.all
        end

        # Lifecycle, valid time and deletion state, applied before any limit.
        def gated(relation, filters, now)
          relation = relation.where(lifecycle: filters.fetch(:lifecycle, %w[active]))
          relation = relation.where(deleted_at: nil)
          relation = relation.where(arel[:valid_from].lteq(now))
          relation = relation.where(arel[:valid_until].eq(nil).or(arel[:valid_until].gt(now)))
          relation = relation.where(kind: filters[:memory_kinds]) if filters[:memory_kinds]
          relation = relation.where(category: filters[:global_categories]) if filters[:global_categories]
          relation
        end

        def suppress_disputed(relation)
          relation.where(
            arel[:has_open_dispute].eq(false).or(
              arel[:authority].eq("user").and(arel[:kind].in(GOVERNING_KINDS))
            )
          )
        end

        def seek(relation, cursor, authorized_scope, filters, generation_vector)
          return relation if cursor.nil?

          position = Serialization::Continuation.decode(cursor, bound: binding_for(authorized_scope, filters, generation_vector))
          recorded_at = Time.iso8601(position.fetch("recorded_at"))
          relation.where(
            arel[:recorded_at].lt(recorded_at).or(
              arel[:recorded_at].eq(recorded_at).and(arel[:memory_key].gt(position.fetch("memory_key")))
            )
          )
        end

        def build_page(rows, candidate_limit, coverage, authorized_scope, filters, generation_vector, now)
          truncated = rows.length > candidate_limit
          page = truncated ? rows.first(candidate_limit) : rows
          items = page.map { |row| Serialization::MemoryItem.from_row(row, coverage: coverage) }
          Page.new(
            items: items.freeze, considered: rows.length, truncated: truncated,
            continuation: truncated ? issue_cursor(page.last, authorized_scope, filters, generation_vector, now) : nil
          )
        end

        def issue_cursor(last, authorized_scope, filters, generation_vector, now)
          Serialization::Continuation.issue(
            position: { "recorded_at" => last.recorded_at.utc.iso8601(6), "memory_key" => last.memory_key },
            bound: binding_for(authorized_scope, filters, generation_vector), now: now
          )
        end

        def binding_for(authorized_scope, filters, generation_vector)
          {
            "scope_digest" => Contracts::Canonical.digest(authorized_scope.to_h),
            "query_digest" => Contracts::Canonical.digest(nil),
            "filter_digest" => Contracts::Canonical.digest(filters),
            "mode" => "exact",
            "ranking_config_version" => RANKING_CONFIG_VERSION,
            "generation_vector_digest" => generation_vector&.digest
          }
        end

        def arel = records.memory_search_document.arel_table
      end
    end
  end
end
