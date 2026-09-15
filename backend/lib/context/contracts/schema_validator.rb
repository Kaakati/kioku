# frozen_string_literal: true

module Context
  module Contracts
    # Structural validation of an untrusted payload against one schema from the shared
    # artifact.
    #
    # This is what replaces the core-derived NAME BLACKLIST (D6). BaseController checked
    # seven names at body top level and the host checked three inside the envelope, so
    # neither was complete and `{"envelope":{"authority":"user"}}` walked past both. The
    # artifact's answer is structural: every request object is closed, so an undeclared
    # key is refused at whatever depth it was supplied — `authority` nested in
    # `correlation`, and `priority`, which no blacklist would ever carry.
    #
    # Every violation is reported, not just the first, and each names a JSON Pointer
    # rather than a value: a refusal is operator-facing and content-redacted, so it never
    # echoes what the caller sent back onto the wire or into the log.
    class SchemaValidator
      Violation = Struct.new(:pointer, :reason, :undeclared, keyword_init: true)

      TYPES = {
        "object" => ->(value) { value.is_a?(Hash) },
        "array" => ->(value) { value.is_a?(Array) },
        "string" => ->(value) { value.is_a?(String) },
        "integer" => ->(value) { value.is_a?(Integer) },
        "number" => ->(value) { value.is_a?(Numeric) },
        "boolean" => ->(value) { [true, false].include?(value) },
        "null" => ->(value) { value.nil? }
      }.freeze

      # Applicators this validator does not implement. Silently skipping one would leave
      # the properties behind it unvalidated, which is the defect itself, so an artifact
      # that grows one fails loudly here instead.
      UNIMPLEMENTED_KEYWORDS = %w[oneOf allOf anyOf if propertyNames patternProperties].freeze

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
        details[:rejected_fields] = undeclared if undeclared.any?
        details[:fields] = fields if fields.any?

        Errors::InvalidRequest.new(
          "the request envelope failed contract validation: " \
          "#{violations.map { |v| "#{v.pointer} #{v.reason}" }.join('; ')}",
          details: details
        )
      end

      def field_name(pointer)
        pointer.delete_prefix(@base).delete_prefix("/").tr("/", ".")
      end

      # A wrong type makes every other rule meaningless, so nothing else is reported for
      # a node whose type already failed.
      def check(schema, value, pointer, out)
        return out unless schema.is_a?(Hash)

        guard!(schema)
        size = out.size
        type_rule(schema, value, pointer, out)
        return out unless out.size == size

        scalar_rules(schema, value, pointer, out)
        object_rules(schema, value, pointer, out) if value.is_a?(Hash)
        array_rules(schema, value, pointer, out) if value.is_a?(Array)
        forbidden(schema["not"], value, pointer, out) if schema.key?("not")
        out
      end

      def guard!(schema)
        unhandled = UNIMPLEMENTED_KEYWORDS.select { |keyword| schema.key?(keyword) }
        return if unhandled.empty?

        raise ArgumentError, "the contract uses #{unhandled.join(', ')}, which this validator " \
                             "does not implement; the fields behind it would go unchecked"
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
      # something, and a whitespace-only key names nothing.
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

      def object_rules(schema, value, pointer, out)
        Array(schema["required"]).each do |name|
          refuse(out, "#{pointer}/#{name}", "is required") unless value.key?(name)
        end
        declared = schema["properties"]
        if declared.is_a?(Hash)
          declared.each { |name, sub| check(sub, value[name], "#{pointer}/#{name}", out) if value.key?(name) }
        end
        closure(schema, value, pointer, out)
      end

      # "The published surface is the whole accepted surface": an undeclared key is
      # refused by name rather than ignored, so a caller learns their field did nothing.
      def closure(schema, value, pointer, out)
        additional = schema["additionalProperties"]
        return if additional.nil? || additional == true

        (value.keys - Array(schema["properties"]&.keys)).each do |name|
          child = "#{pointer}/#{name}"
          next check(additional, value[name], child, out) if additional.is_a?(Hash)

          refuse(out, child, "is not a declared field of this call", undeclared: true)
        end
      end

      def array_rules(schema, value, pointer, out)
        refuse(out, pointer, "must carry at least #{schema['minItems']} entries") if
          schema["minItems"] && value.size < schema["minItems"]
        refuse(out, pointer, "must carry at most #{schema['maxItems']} entries") if
          schema["maxItems"] && value.size > schema["maxItems"]
        return unless schema["items"].is_a?(Hash)

        value.each_with_index { |item, index| check(schema["items"], item, "#{pointer}/#{index}", out) }
      end

      # The artifact uses `not` in one shape: an anyOf of required-key lists, which is how
      # a read envelope refuses the idempotency fields. Naming the offending keys is what
      # lets the refusal say WHICH field is not accepted on a read.
      def forbidden(subschema, value, pointer, out)
        keys = forbidden_keys(subschema, value)
        return if keys.empty?

        keys.each { |name| refuse(out, "#{pointer}/#{name}", "is not accepted on this call", undeclared: true) }
      end

      def forbidden_keys(subschema, value)
        return [] unless value.is_a?(Hash) && subschema.is_a?(Hash)

        branches = subschema["anyOf"]
        raise ArgumentError, "`not` is only implemented for an anyOf of required lists" unless
          branches.is_a?(Array) && branches.all? { |branch| branch.keys == ["required"] }

        branches.flat_map { |branch| branch.fetch("required") }.select { |name| value.key?(name) }
      end

      def refuse(out, pointer, reason, undeclared: false)
        out << Violation.new(pointer: pointer, reason: reason, undeclared: undeclared)
      end
    end
  end
end
