# frozen_string_literal: true

module Context
  module Services
    module Memories
      class Remember
        # The inputs of one context_remember call, normalised.
        #
        # A value object only: whether these inputs are acceptable is the
        # service's decision, not this type's.
        class Request
          attr_reader :actor, :envelope, :kind, :title, :body, :evidence,
                      :memory_key, :applicability, :lifecycle,
                      :store_kind, :project_key, :category, :origin_project_key

          def initialize(actor:, envelope:, kind:, destination:, title:, body:, evidence:,
                         memory_key: nil, applicability: nil, mandatory: false,
                         lifecycle: nil, received_body: nil)
            @received_body = received_body
            @actor = actor
            @envelope = envelope
            @kind = kind
            @title = title
            @body = body
            @evidence = Array(evidence)
            @memory_key = memory_key
            @applicability = applicability
            @mandatory = mandatory
            @lifecycle = lifecycle
            read_destination(destination)
            freeze
          end

          def global?
            store_kind == :global
          end

          def project?
            store_kind == :project
          end

          # memories.project_key is the owner, and a global record owns none
          # (plan 5.2: exactly one destination).
          def owned_project_key
            project? ? project_key : nil
          end

          def mandatory?
            @mandatory
          end

          # Core-derived, never caller-supplied (frozen contract, labels.authority).
          def authority
            actor.authority
          end

          def expected_revision
            envelope.expected_revision
          end

          # E1. The digest the core computes over the content it actually received.
          #
          # `contract.json request_digest.authority`: "The core RECOMPUTES the digest
          # over the received body and compares it to the asserted value. A
          # caller-asserted digest never decides a durability claim."
          #
          # The receipt stores this and the replay comparison reads it, so a reused
          # idempotency key is answered by what the core holds rather than by what the
          # caller says it sent. The asserted string stays on the wire for the caller's
          # own correlation and decides nothing: asserting a stale digest can no longer
          # win a `saved` for content that was never stored, and asserting a different
          # digest for identical content can no longer lose the caller its own receipt.
          #
          # Not memoized: this object is frozen, and the value is read at most twice.
          def computed_digest
            Contracts::RequestDigest.compute(@received_body || digest_input)
          end

          # The canonical body the digest covers. RequestDigest drops the declared
          # exclusions (request_id, deadline_ms, correlation) and request_digest itself,
          # then sorts keys at every depth, so field order cannot change the result
          # while a removed evidence link can. project_key is included deliberately:
          # "the same payload in a different project is a different request".
          def digest_input
            {
              "envelope" => {
                "schema_version" => envelope.schema_version,
                "scope" => { "store" => store_kind.to_s, "project_key" => project_key },
                "idempotency_key" => envelope.idempotency_key,
                "expected_revision" => envelope.expected_revision
              },
              "kind" => kind.to_s,
              "destination" => {
                "store_kind" => store_kind.to_s, "project_key" => project_key,
                "category" => category, "origin_project_key" => origin_project_key
              },
              "title" => title, "body" => body,
              "evidence" => evidence.map { |entry| stringify(entry) },
              "memory_key" => memory_key,
              "applicability" => stringify(applicability),
              "mandatory" => mandatory?,
              "lifecycle" => lifecycle&.to_s
            }
          end

          def applicability_conditions
            return nil if applicability.nil?

            applicability[:conditions] || applicability["conditions"]
          end

          # Plan 1.3: automatically extracted reusable lessons are stored as
          # proposed assistant-authored records; they do not become governing
          # user preferences because several agents repeat them.
          def effective_lifecycle
            return lifecycle if lifecycle

            global? && authority != :user ? :proposed : :active
          end

          private

          # Symbol and string keys must not produce two different digests for one
          # request, so every nested key is rendered as a string before canonicalization.
          def stringify(value)
            case value
            when Hash then value.each_with_object({}) { |(k, v), out| out[k.to_s] = stringify(v) }
            when Array then value.map { |item| stringify(item) }
            when Symbol then value.to_s
            else value
            end
          end

          def read_destination(destination)
            fields = destination.to_h.transform_keys(&:to_sym)
            @store_kind = fields[:store_kind].to_sym
            @project_key = fields[:project_key]
            @category = fields[:category]
            @origin_project_key = fields[:origin_project_key]
          end
        end
      end
    end
  end
end
