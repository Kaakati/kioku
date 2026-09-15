# frozen_string_literal: true

require_relative "schemas/common"
require_relative "schemas/memory"
require_relative "schemas/retrieval"
require_relative "schemas/task"

module Kioku
  # The six frozen tool definitions. The surface stays at six: preference and
  # override records are typed context_remember variants, and project
  # registration and root management belong to operator and UI setup APIs.
  module Schemas
    DESCRIPTIONS = {
      "context_search" => "Return a bounded, scope-authorized, labeled candidate set -- the active " \
                          "project's memories plus applicable global engineering records, retained " \
                          "solution cases, code and evidence -- found by exact handle, lexical BM25 " \
                          "match, or bounded typed traversal, without asserting that any candidate is true.",
      "context_fetch" => "Return the exact bytes, ranges or revisions behind already-identified handles " \
                         "in bounded batches, re-authorizing scope and re-checking deletion state on " \
                         "every request.",
      "context_related" => "Answer a typed relationship question -- callers, decision rationale, change " \
                           "impact, evidence lineage -- by bounded traversal from authorized seeds, " \
                           "returning explicit depth, fanout and coverage limits instead of an " \
                           "exhaustive graph.",
      "context_remember" => "Commit one evidence-linked durable memory revision to an explicitly named " \
                            "project or global destination. It returns saved only after canonical commit " \
                            "and queued only after durable host enqueue.",
      "context_feedback" => "Attach an attributed dispute or usefulness signal to one exact memory " \
                            "revision, project or global, preserving the objection and its disposition " \
                            "without mutating or cancelling the target.",
      "context_task" => "Maintain one project-bound task's contract, material claims, immutable " \
                        "candidates, planned checks, checkpoints, assessments and scoped completion " \
                        "through a discriminated eight-operation schema."
    }.freeze

    module_function

    def input_schema(tool)
      case tool
      when "context_search" then Retrieval.search
      when "context_fetch" then Retrieval.fetch
      when "context_related" then Retrieval.related
      when "context_remember" then Memory.remember
      when "context_feedback" then Memory.feedback
      when "context_task" then Task.schema
      else raise Kioku.unsupported_operation("unknown tool", { "requested" => tool })
      end
    end

    def description(tool)
      DESCRIPTIONS.fetch(tool) { raise Kioku.unsupported_operation("unknown tool", { "requested" => tool }) }
    end
  end
end
