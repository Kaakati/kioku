# frozen_string_literal: true

require_relative "contract_fixtures"

module Kioku
  module TestSupport
    # Turns one conformance case's declared expectation into assertions against a
    # real parser or validator.
    #
    # The expectation vocabulary is the artifact's, not this file's: `outcome`,
    # `code`, `field`, `rejected_fields` and `details` are the keys the case files
    # use, and nothing here decides what any of them should be.
    #
    # Outcome and detail are asserted by SEPARATE test methods. "the wrong outcome"
    # and "the right outcome refused for the wrong field" are different defects and
    # a run that reports them together is harder to act on than one that does not.
    module ContractAssertions
      # Returns the parsed value on an acceptance and the Kioku::Error on a refusal.
      def assert_outcome(expect, context)
        outcome = begin
          [:accepted, yield]
        rescue Kioku::Error => e
          [:refused, e]
        end

        state, value = outcome
        if expect.fetch("outcome") == "accepted"
          assert_equal :accepted, state,
                       "#{context}: the contract declares this accepted, but it was refused with " \
                       "#{state == :refused ? "#{value.code}: #{value.message}" : ''}"
        else
          assert_equal :refused, state,
                       "#{context}: the contract declares this refused with #{expect.fetch('code')}, " \
                       "but it was accepted"
          assert_equal expect.fetch("code"), value.code, "#{context}: #{value.message}"
        end
        value
      end

      # "Every refusal names a field, never a value." A refusal that names a
      # DIFFERENT field than the contract declares is refusing for the wrong
      # reason, which is how a closed-surface rejection was mistaken for an enum
      # check and how kioku.invalid_request came to stand in for five conditions.
      def assert_refusal_detail(expect, error, context)
        return if expect.fetch("outcome") == "accepted"
        return unless error.is_a?(Kioku::Error)

        (Array(expect["rejected_fields"]) + Array(expect["field"])).each do |field|
          assert_names_field(error, field, context)
        end
        (expect["details"] || {}).each do |key, value|
          assert_equal value, detail(error, key),
                       "#{context}: the refusal's details.#{key} does not carry the declared reason"
        end
      end

      def assert_names_field(error, field, context)
        name = field.to_s.split(%r{[/.]}).reject(&:empty?).last
        named = Array(detail(error, "fields")).include?(field) ||
                Array(detail(error, "rejected_fields")).include?(field) ||
                error.message.include?(name)

        assert named, "#{context}: the refusal must name #{field.inspect}, but it reported " \
                      "#{error.message.inspect} with details #{error.details.inspect}"
      end

      def detail(error, key)
        details = error.details || {}
        details[key.to_s] || details[key.to_sym]
      end

      # Runs every case in a fixture list and reports all failures at once, so one
      # run names every divergence rather than the first. A new case added to the
      # artifact is exercised without this suite being edited.
      def each_case(cases, side:)
        failures = []
        cases.each do |kase|
          next unless Array(kase["sides"]).empty? || Array(kase["sides"]).include?(side)

          begin
            yield kase
          rescue Minitest::Assertion => e
            failures << "#{kase.fetch('id')}: #{e.message}"
          end
        end
        assert_empty failures, "#{failures.size} conformance case(s) failed:\n- #{failures.join("\n- ")}"
      end
    end
  end
end
