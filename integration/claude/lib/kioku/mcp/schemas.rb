# frozen_string_literal: true

require_relative "schemas/shared"
require_relative "schemas/retrieval"
require_relative "schemas/mutation"
require_relative "schemas/task"

module Kioku
  module Mcp
    # "The MCP tool surface stays at six tools" [contracts: envelope.notes; plan §6.2].
    # Project registration and root management stay on the operator/UI setup APIs and are
    # deliberately absent from this surface.
    module Schemas
      DESCRIPTIONS = {
        "context_search" => "Return a bounded, scope-authorized, labeled candidate set by exact handle, " \
                            "lexical BM25 match, or bounded typed traversal, without asserting that any " \
                            "candidate is true.",
        "context_fetch" => "Return the exact bytes, ranges or revisions behind already-identified handles " \
                           "in bounded batches, re-authorizing scope on every request.",
        "context_related" => "Answer a typed relationship question by bounded traversal from authorized " \
                             "seeds, returning explicit depth, fanout and coverage limits.",
        "context_remember" => "Commit one evidence-linked durable memory revision to an explicitly named " \
                              "project or global destination. Returns saved only after canonical commit.",
        "context_feedback" => "Attach an attributed dispute or usefulness signal to one exact memory " \
                              "revision, without mutating or cancelling the target.",
        "context_task" => "Maintain one project-bound task's contract, claims, candidates, checks, " \
                          "checkpoints, assessments and scoped completion."
      }.freeze

      module_function

      def all
        {
          "context_search" => Retrieval.search,
          "context_fetch" => Retrieval.fetch,
          "context_related" => Retrieval.related,
          "context_remember" => Mutation.remember,
          "context_feedback" => Mutation.feedback,
          "context_task" => Task.schema
        }
      end

      def description(tool)
        DESCRIPTIONS.fetch(tool)
      end
    end
  end
end
