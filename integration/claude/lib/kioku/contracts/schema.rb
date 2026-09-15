# frozen_string_literal: true

require_relative "../errors"

module Kioku
  module Contracts
    # Structural validation of one payload against one schema from the shared artifact.
    #
    # This is what replaces the runtime core-derived NAME BLACKLIST (D6). A blacklist
    # checked at one depth is bypassed by nesting the name one level deeper, which is
    # exactly the observed defect: the host checked three names inside the envelope and
    # the core checked seven at body top level, and neither was complete. The artifact's
    # answer is structural — every request object is closed, so `authority` is refused
    # inside `correlation`, and `priority`, which no blacklist would ever carry, is
    # refused with it.
    #
    # Every violation is reported, not just the first, and each one names a JSON Pointer
    # rather than a value: a refusal is operator-facing and content-redacted, so a
    # rejected write never echoes the remembered body back to the model.
    class Schema
      Violation = Struct.new(:pointer, :reason, :undeclared, keyword_init: true)

      # The JSON type names the artifact uses, and what satisfies each one in Ruby.
      TYPES = {
        "object" => ->(value) { value.is_a?(Hash) },
        "array" => ->(value) { value.is_a?(Array) },
        "string" => ->(value) { value.is_a?(String) },
        "integer" => ->(value) { value.is_a?(Integer) },
        "number" => ->(value) { value.is_a?(Numeric) && !value.is_a?(TrueClass) },
        "boolean" => ->(value) { value == true || value == false },
        "null" => ->(value) { value.nil? }
      }.freeze

      def initialize(schema, base: "")
        @schema = schema
        @base = base
      end

      def validate!(payload)
        violations = check(@schema, payload, @base, [])
        return payload if violations.empty?

        raise refusal(violations)
      end

      private

      # The artifact distinguishes the two detail lists. `rejected_fields` carries the
      # JSON Pointer of each undeclared key, because the whole point of the closure rule
      # is to say at what DEPTH the key was smuggled in. `fields` carries the field's
      # name relative to the object being validated — `contract.json` states the digest
      # mismatch as `details.fields = ["request_digest"]`, and the conformance cases name
      # `deadline_ms` and `scope.store` the same way.
      def refusal(violations)
        undeclared = violations.select(&:undeclared).map(&:pointer).uniq
        fields = violations.reject(&:undeclared).map { |v| field_name(v.pointer) }.uniq
        details = {}
        details["rejected_fields"] = undeclared unless undeclared.empty?
        details["fields"] = fields unless fields.empty?

        Kioku::Error.new("kioku.invalid_request", details: details,
                                                  message: "the request failed contract validation: " \
                                                           "#{violations.map { |v| "#{v.pointer} #{v.reason}" }.join('; ')}")
      end

      def field_name(pointer)
        pointer.delete_prefix(@base).delete_prefix("/").tr("/", ".")
      end

      # A wrong type makes every other rule meaningless, so nothing else is reported for
      # a node whose type already failed.
      def check(schema, value, pointer, out)
        return out unless schema.is_a?(Hash)

        size = out.size
        type_rule(schema, value, pointer, out)
        return out unless out.size == size

        value_rules(schema, value, pointer, out)
        composition(schema, value, pointer, out)
        out
      end

      def value_rules(schema, value, pointer, out)
        scalar_rules(schema, value, pointer, out)
        object_rules(schema, value, pointer, out) if value.is_a?(Hash)
        array_rules(schema, value, pointer, out) if value.is_a?(Array)
      end

      def type_rule(schema, value, pointer, out)
        declared = Array(schema["type"])
        return if declared.empty?
        return if declared.any? { |name| TYPES.fetch(name).call(value) }

        refuse(out, pointer, "must be #{declared.join(' or ')}")
      end

      def scalar_rules(schema, value, pointer, out)
        refuse(out, pointer, "must be one of: #{schema['enum'].join(', ')}") if
          schema.key?("enum") && !schema["enum"].include?(value)
        refuse(out, pointer, "must be #{schema['const']}") if
          schema.key?("const") && schema["const"] != value

        string_rules(schema, value, pointer, out) if value.is_a?(String)
        numeric_rules(schema, value, pointer, out) if value.is_a?(Numeric)
      end

      # `minLength: 1` is the artifact's non_empty_string: the value has to NAME
      # something. A whitespace-only title names nothing, so it is refused under the same
      # pointer rather than counted as one character.
      def string_rules(schema, value, pointer, out)
        minimum = schema["minLength"]
        refuse(out, pointer, "must be non-blank") if minimum.to_i.positive? && value.strip.empty?
        refuse(out, pointer, "must be at least #{minimum} characters") if
          minimum && value.length < minimum
        refuse(out, pointer, "must be at most #{schema['maxLength']} characters") if
          schema["maxLength"] && value.length > schema["maxLength"]
        refuse(out, pointer, "does not match the declared pattern") if
          schema["pattern"] && !Regexp.new(schema["pattern"]).match?(value)
      end

      def numeric_rules(schema, value, pointer, out)
        refuse(out, pointer, "must be at least #{schema['minimum']}") if
          schema["minimum"] && value < schema["minimum"]
        refuse(out, pointer, "must be at most #{schema['maximum']}") if
          schema["maximum"] && value > schema["maximum"]
      end

      # --- objects ----------------------------------------------------------------

      def object_rules(schema, value, pointer, out)
        Array(schema["required"]).each do |name|
          refuse(out, "#{pointer}/#{name}", "is required") unless value.key?(name)
        end
        property_rules(schema, value, pointer, out)
        closure(schema, value, pointer, out)
        property_name_rules(schema, value, pointer, out)
        count_rules(schema, value, pointer, out)
      end

      def property_rules(schema, value, pointer, out)
        declared = schema["properties"]
        return unless declared.is_a?(Hash)

        declared.each do |name, subschema|
          check(subschema, value[name], "#{pointer}/#{name}", out) if value.key?(name)
        end
      end

      # "The published surface is the whole accepted surface": an undeclared key is
      # refused by name rather than ignored, so a caller learns their field did nothing.
      def closure(schema, value, pointer, out)
        additional = schema["additionalProperties"]
        return if additional.nil? || additional == true

        undeclared = value.keys - Array(schema["properties"]&.keys)
        return if undeclared.empty?

        undeclared.each do |name|
          child = "#{pointer}/#{name}"
          next check(additional, value[name], child, out) if additional.is_a?(Hash)

          refuse(out, child, "is not a declared field of this call", undeclared: true)
        end
      end

      def property_name_rules(schema, value, pointer, out)
        subschema = schema["propertyNames"]
        return unless subschema.is_a?(Hash)

        value.each_key { |name| check(subschema, name, "#{pointer}/#{name}", out) }
      end

      def count_rules(schema, value, pointer, out)
        refuse(out, pointer, "must carry at least #{schema['minProperties']} field(s)") if
          schema["minProperties"] && value.size < schema["minProperties"]
        refuse(out, pointer, "must carry at most #{schema['maxProperties']} field(s)") if
          schema["maxProperties"] && value.size > schema["maxProperties"]
      end

      # --- arrays -----------------------------------------------------------------

      def array_rules(schema, value, pointer, out)
        refuse(out, pointer, "must carry at least #{schema['minItems']} entries") if
          schema["minItems"] && value.size < schema["minItems"]
        refuse(out, pointer, "must carry at most #{schema['maxItems']} entries") if
          schema["maxItems"] && value.size > schema["maxItems"]
        return unless schema["items"].is_a?(Hash)

        value.each_with_index { |item, index| check(schema["items"], item, "#{pointer}/#{index}", out) }
      end

      # --- composition ------------------------------------------------------------

      def composition(schema, value, pointer, out)
        Array(schema["allOf"]).each { |branch| conditional(branch, value, pointer, out) }
        conditional(schema, value, pointer, out) if schema.key?("if")
        one_of(schema["oneOf"], value, pointer, out) if schema["oneOf"].is_a?(Array)
        any_of(schema["anyOf"], value, pointer, out) if schema["anyOf"].is_a?(Array)
        forbidden(schema["not"], value, pointer, out) if schema.key?("not")
      end

      def conditional(branch, value, pointer, out)
        return check(branch, value, pointer, out) unless branch.key?("if")

        taken = matches?(branch["if"], value, pointer) ? branch["then"] : branch["else"]
        check(taken, value, pointer, out) if taken.is_a?(Hash)
      end

      # A discriminated union reports the branch the caller SELECTED. Reporting "no
      # alternative matched" for context_task would name the union instead of the one
      # field the caller got wrong, and eight branch reports would name seven fields the
      # caller never sent.
      def one_of(branches, value, pointer, out)
        matching = branches.count { |branch| matches?(branch, value, pointer) }
        return if matching == 1

        selected = discriminated(branches, value)
        return check(selected, value, pointer, out) if selected && matching.zero?

        refuse(out, pointer, "must satisfy exactly one of the #{branches.size} declared alternatives")
      end

      def any_of(branches, value, pointer, out)
        return if branches.any? { |branch| matches?(branch, value, pointer) }

        refuse(out, pointer, "must satisfy one of the #{branches.size} declared alternatives")
      end

      # The artifact uses `not` in one shape only: an anyOf of required-key lists, which
      # is how a read envelope refuses the idempotency fields. Naming the offending keys
      # is what lets the refusal say WHICH field is not accepted on a read.
      def forbidden(subschema, value, pointer, out)
        return unless matches?(subschema, value, pointer)

        keys = forbidden_keys(subschema, value)
        return refuse(out, pointer, "matches a shape this call refuses", undeclared: true) if keys.empty?

        keys.each do |name|
          refuse(out, "#{pointer}/#{name}", "is not accepted on this call", undeclared: true)
        end
      end

      def forbidden_keys(subschema, value)
        return [] unless value.is_a?(Hash)

        Array(subschema["anyOf"]).flat_map { |branch| Array(branch["required"]) }
                                 .select { |name| value.key?(name) }
      end

      # The branch whose const-pinned properties all match what the caller sent. A branch
      # that pins nothing discriminates nothing, so it is never selected.
      def discriminated(branches, value)
        return nil unless value.is_a?(Hash)

        selected = branches.select do |branch|
          pins = const_pins(branch)
          pins.any? && pins.all? { |name, pinned| value[name] == pinned }
        end
        selected.size == 1 ? selected.first : nil
      end

      def const_pins(branch)
        declared = branch.is_a?(Hash) ? branch["properties"] : nil
        return {} unless declared.is_a?(Hash)

        declared.each_with_object({}) do |(name, subschema), pins|
          pins[name] = subschema["const"] if subschema.is_a?(Hash) && subschema.key?("const")
        end
      end

      def matches?(schema, value, pointer)
        check(schema, value, pointer, []).empty?
      end

      def refuse(out, pointer, reason, undeclared: false)
        out << Violation.new(pointer: pointer, reason: reason, undeclared: undeclared)
      end
    end
  end
end
