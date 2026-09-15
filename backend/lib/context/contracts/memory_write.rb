# frozen_string_literal: true

module Context
  module Contracts
    # The context_remember request (Plan §4 names this file explicitly).
    #
    # Nothing here decides anything: it decodes and bounds the request. The
    # authority label is absent on purpose — it is derived from the
    # authenticated transport by Context::Domain::Memories::AuthorityPolicy,
    # and a request that supplies it is already rejected by the envelope.
    class MemoryWrite < Data.define(
      :envelope, :kind, :destination, :title, :body, :evidence, :applicability,
      :memory_key, :lifecycle, :rationale, :tradeoffs, :valid_from, :valid_until,
      :links, :derivative, :override, :mandatory, :task_key, :source_anchor, :attempt
    )
      TOOL = "context_remember"
      FIELDS = %w[
        envelope kind destination title body evidence applicability memory_key lifecycle
        rationale tradeoffs valid_from valid_until links derivative override mandatory
        origin_project_key task_key source_anchor attempt token_budget
      ].freeze
      LINK_KINDS = %w[supersedes derived_from constrains proposed_for rejected_in].freeze
      ATTEMPT_FIELDS = %w[problem hypothesis actions observations verdict retry_conditions].freeze
      ATTEMPT_VERDICTS = %w[open succeeded failed abandoned].freeze

      def initialize(envelope:, kind:, destination:, title:, body:, evidence:, applicability: nil,
                     memory_key: nil, lifecycle: nil, rationale: nil, tradeoffs: nil, valid_from: nil,
                     valid_until: nil, links: {}, derivative: nil, override: nil, mandatory: false,
                     task_key: nil, source_anchor: nil, attempt: nil)
        super
      end

      def self.parse(payload, started_at: Time.now.utc)
        request = Validator.hash!(Validator.deep_stringify(payload), field: "request")
        Validator.reject_core_derived!(request)
        Validator.reject_unknown!(request, allowed: FIELDS)
        envelope = Envelope.parse(Validator.required(request, "envelope"), tool: TOOL, mutation: true, started_at: started_at)
        envelope = envelope.with(token_budget: tool_token_budget(request)) unless request["token_budget"].nil?
        new(**core_attributes(request, envelope).merge(optional_attributes(request))).validate!
      end

      def self.tool_token_budget(request)
        Validator.integer!(request["token_budget"], field: "token_budget", min: 1, max: 1_000_000)
      end

      def self.core_attributes(request, envelope)
        destination = Destination.parse(Validator.required(request, "destination"),
                                        origin_project_key: origin_project_key(request))
        {
          envelope: envelope,
          kind: Validator.enum!(Validator.required(request, "kind"), field: "kind", allowed: Vocabulary.memory_kinds),
          destination: destination,
          title: Validator.string!(Validator.required(request, "title"), field: "title", max: 200),
          body: Validator.string!(Validator.required(request, "body"), field: "body", max: 16_384),
          evidence: EvidenceRef.parse_list(Validator.required(request, "evidence"), field: "evidence", min: 1, max: 50),
          applicability: parse_applicability(request, destination)
        }
      end

      def self.optional_attributes(request)
        {
          memory_key: request["memory_key"] && Validator.string!(request["memory_key"], field: "memory_key", max: 128),
          lifecycle: request["lifecycle"] && Validator.enum!(request["lifecycle"], field: "lifecycle", allowed: Vocabulary.writable_lifecycles),
          rationale: request["rationale"] && Validator.string!(request["rationale"], field: "rationale", max: 8192),
          tradeoffs: request["tradeoffs"] && Validator.string!(request["tradeoffs"], field: "tradeoffs", max: 8192),
          valid_from: Validator.time!(request["valid_from"], field: "valid_from"),
          valid_until: Validator.time!(request["valid_until"], field: "valid_until"),
          links: parse_links(request["links"]),
          derivative: request["derivative"] && Derivative.parse(request["derivative"]),
          override: request["override"] && OverrideRequest.parse(request["override"]),
          mandatory: Validator.boolean!(request.fetch("mandatory", false), field: "mandatory"),
          task_key: request["task_key"] && Validator.string!(request["task_key"], field: "task_key", max: 128),
          source_anchor: parse_source_anchor(request["source_anchor"]),
          attempt: parse_attempt(request["attempt"])
        }
      end

      def self.origin_project_key(request)
        value = request["origin_project_key"]
        value && Validator.string!(value, field: "origin_project_key", max: 128)
      end

      def self.parse_applicability(request, destination)
        value = request["applicability"]
        if destination.global?
          Validator.invalid!("applicability", "required_for_global_destination") if value.nil?
          return ApplicabilityConditions.parse(value)
        end
        value.nil? ? nil : ApplicabilityConditions.parse(value)
      end

      def self.parse_links(value)
        return {}.freeze if value.nil?

        links = Validator.hash!(value, field: "links")
        Validator.reject_unknown!(links, allowed: LINK_KINDS, field: "links")
        LINK_KINDS.filter_map do |name|
          next unless links.key?(name)

          [name, Validator.string_array!(links[name], field: "links.#{name}", max: 32).freeze]
        end.to_h.freeze
      end

      # The versioned source-anchor schema is a separate Phase 0 deliverable and
      # is not frozen yet, so only the envelope of the anchor is enforced here:
      # it must be a versioned object, never free text and never an instruction.
      def self.parse_source_anchor(value)
        return nil if value.nil?

        anchor = Validator.hash!(value, field: "source_anchor")
        Validator.string!(Validator.required(anchor, "schema_version", field: "source_anchor.schema_version"),
                          field: "source_anchor.schema_version", max: 64)
        anchor.freeze
      end

      def self.parse_attempt(value)
        return nil if value.nil?

        attempt = Validator.hash!(value, field: "attempt")
        Validator.reject_unknown!(attempt, allowed: ATTEMPT_FIELDS, field: "attempt")
        Validator.string!(Validator.required(attempt, "problem", field: "attempt.problem"), field: "attempt.problem", max: 4096)
        Validator.enum!(Validator.required(attempt, "verdict", field: "attempt.verdict"), field: "attempt.verdict", allowed: ATTEMPT_VERDICTS)
        %w[actions observations].each { |name| Validator.string_array!(attempt[name], field: "attempt.#{name}", max: 64, item_max: 2048) if attempt[name] }
        attempt.freeze
      end

      private_class_method :core_attributes, :optional_attributes, :origin_project_key, :tool_token_budget,
                           :parse_applicability, :parse_links, :parse_source_anchor, :parse_attempt

      def validate!
        Validator.invalid!("attempt", "only_valid_for_kind_attempt") if attempt && kind != "attempt"
        Validator.invalid!("valid_until", "not_after_valid_from") if valid_from && valid_until && valid_until <= valid_from
        Validator.invalid!("derivative", "requires_project_destination") if derivative && !destination.project?
        Validator.invalid!("override", "requires_project_destination") if override && !destination.project?
        Validator.invalid!("memory_key", "required_with_expected_revision") if envelope.expected_revision && memory_key.nil?
        self
      end

      def appending? = !memory_key.nil?
      def publish_derivative? = !derivative.nil? && derivative.publish_global
      def scope = envelope.scope
      def project_key = destination.project_key
      def contradicting_evidence = evidence.select(&:contradicting?)
    end
  end
end
