# frozen_string_literal: true

# The lexical projection must carry the lifecycle of the revision it projects.
#
# Frozen contract: "Scope, deletion and lifecycle gates still precede ranking and
# must hold identically on every route — exact, lexical, related, facet,
# aggregate and JOIN." `Queries::Search::Lexical` said so in a comment and could
# not do it, because there was nothing on this table to gate on: a retracted or
# superseded head stayed fully retrievable by BM25 for as long as its words
# matched. That is the one outcome retraction exists to prevent.
#
# NOT NULL with no default on purpose. A default would let a publisher that
# forgot the column produce a row that reads as eligible, which is the fail-open
# direction of exactly the gate being added here; `memory_revisions.lifecycle`
# is declared the same way for the same reason.
class ProjectLifecycleIntoSearchDocuments < ActiveRecord::Migration[8.1]
  LIFECYCLES = %w[proposed active superseded retracted].freeze

  def change
    add_column :memory_search_documents, :lifecycle, :text, null: false
    # The same four values as memory_revisions.lifecycle: a projection that could
    # carry a fifth would be describing a revision state that cannot exist.
    add_check_constraint :memory_search_documents,
                         "lifecycle IN (#{quoted(LIFECYCLES)})",
                         name: "memory_search_documents_lifecycle_vocabulary"
  end

  private

  def quoted(values)
    values.map { |value| "'#{value}'" }.join(", ")
  end
end
