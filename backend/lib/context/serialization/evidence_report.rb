# frozen_string_literal: true

module Context
  module Serialization
    # Renders an evidence eligibility outcome and turns its rejections into
    # coverage gaps.
    #
    # Rejections are reported, never dropped. A rejected `contradicts` link is
    # the one that matters most: contrary evidence is never the thing discarded
    # to make a record look better, so it is called out separately in the gap
    # detail.
    module EvidenceReport
      GAP_KINDS = {
        "not_found" => "resolver_hole",
        "deleted" => "missing_object",
        "unavailable" => "missing_object",
        "scope_mismatch" => "scope_excluded",
        "anchor_invalid" => "resolver_hole"
      }.freeze

      module_function

      def accepted_wire(outcome)
        outcome.accepted.map do |item|
          { "ref" => handle_wire(item.ref), "relation" => item.relation, "restricted_source" => item.restricted_source }
        end
      end

      def rejected_wire(outcome)
        outcome.rejected.map do |item|
          { "ref" => handle_wire(item.ref), "relation" => item.relation, "reason" => item.reason }
        end
      end

      def handle_wire(handle)
        { "kind" => handle.kind, "key" => handle.key, "revision" => handle.revision }
      end

      # Mutations report which requested links were accepted (contract:
      # coverage on a mutation describes exactly that).
      def coverage(outcome, requested:)
        declared = { "requested_evidence" => requested.map { |ref| handle_wire(ref.ref) } }
        considered = requested.length
        returned = outcome.accepted.length
        return Coverage.complete(declared_input_set: declared, considered: considered, returned: returned) if outcome.rejected.empty?

        Coverage.partial(declared_input_set: declared, gaps: gaps(outcome), considered: considered, returned: returned,
                         omitted_count: outcome.rejected.length, omitted_reason: "evidence_ineligible")
      end

      def gaps(outcome)
        outcome.rejected.group_by(&:reason).map do |reason, items|
          contradicting = items.count { |item| item.relation == "contradicts" }
          { kind: GAP_KINDS.fetch(reason), detail: gap_detail(reason, contradicting), count: items.length }.freeze
        end
      end

      def gap_detail(reason, contradicting)
        return "evidence rejected: #{reason}" if contradicting.zero?

        "evidence rejected: #{reason} (#{contradicting} contradicting link(s) among them)"
      end
    end
  end
end
