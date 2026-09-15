# frozen_string_literal: true

require_relative "test_helper"

class TestEnvelope < Minitest::Test
  include Kioku::TestSupport

  def prepare(arguments, mutation: false, deadline: 3_000)
    Kioku::Envelope.prepare(arguments, mutation: mutation, default_deadline_ms: deadline)
  end

  def test_adapter_fills_schema_version_request_id_and_deadline
    envelope, args = prepare({ "envelope" => read_envelope, "mode" => "lexical" })
    assert_equal Kioku::SCHEMA_VERSION, envelope["schema_version"]
    assert Kioku::Ids.uuid?(envelope["request_id"])
    assert_equal 3_000, envelope["deadline_ms"]
    assert_equal({ "mode" => "lexical" }, args)
  end

  def test_scope_is_required
    error = assert_raises(Kioku::Error) { prepare({ "envelope" => {} }) }
    assert_equal "kioku.invalid_request", error.code
  end

  # A missing project binding must never fall back to global.
  def test_project_scope_without_project_key_is_a_binding_error
    error = assert_raises(Kioku::Error) { prepare({ "envelope" => { "scope" => { "store" => "both" } } }) }
    assert_equal "kioku.project_binding_unresolved", error.code
    assert_equal true, error.details["setup_required"]
  end

  def test_global_scope_does_not_need_a_project_key
    envelope, = prepare({ "envelope" => { "scope" => { "store" => "global" } } })
    assert_equal "global", envelope.dig("scope", "store")
  end

  def test_core_derived_identity_fields_are_rejected
    %w[authority actor_principal_id origin_role identity].each do |field|
      error = assert_raises(Kioku::Error) do
        prepare({ "envelope" => read_envelope.merge(field => "user") })
      end
      assert_equal "kioku.invalid_request", error.code
      assert_includes error.details["rejected_fields"], field
    end
  end

  def test_unsupported_schema_version
    error = assert_raises(Kioku::Error) do
      prepare({ "envelope" => read_envelope.merge("schema_version" => "kioku.tool.v2") })
    end
    assert_equal "kioku.unsupported_schema_version", error.code
  end

  def test_deadline_bounds
    assert_raises(Kioku::Error) { prepare({ "envelope" => read_envelope.merge("deadline_ms" => 0) }) }
    assert_raises(Kioku::Error) { prepare({ "envelope" => read_envelope.merge("deadline_ms" => 30_001) }) }
    envelope, = prepare({ "envelope" => read_envelope.merge("deadline_ms" => 30_000) })
    assert_equal 30_000, envelope["deadline_ms"]
  end

  def test_expected_revision_must_be_positive_or_null
    assert_raises(Kioku::Error) { prepare({ "envelope" => read_envelope.merge("expected_revision" => 0) }) }
    envelope, = prepare({ "envelope" => read_envelope.merge("expected_revision" => nil) })
    assert_nil envelope["expected_revision"]
  end

  def test_mutation_is_sealed_with_a_digest_and_derived_idempotency_key
    envelope, = prepare({ "envelope" => read_envelope, "title" => "t" }, mutation: true)
    assert_match(/\Asha256:[0-9a-f]{64}\z/, envelope["request_digest"])
    assert_equal envelope["request_digest"].delete_prefix("sha256:"), envelope["idempotency_key"]
  end

  def test_digest_is_stable_across_key_order_and_request_id
    first, = prepare({ "envelope" => read_envelope, "a" => 1, "b" => 2 }, mutation: true)
    second, = prepare({ "envelope" => read_envelope, "b" => 2, "a" => 1 }, mutation: true)
    refute_equal first["request_id"], second["request_id"]
    assert_equal first["request_digest"], second["request_digest"]
  end

  # Digest input includes project_key, so the same payload in another project
  # is a different request.
  def test_digest_changes_with_project_key
    first, = prepare({ "envelope" => read_envelope(project_key: "alpha"), "a" => 1 }, mutation: true)
    second, = prepare({ "envelope" => read_envelope(project_key: "beta"), "a" => 1 }, mutation: true)
    refute_equal first["request_digest"], second["request_digest"]
  end

  def test_digest_ignores_deadline_and_correlation
    base = read_envelope
    first, = prepare({ "envelope" => base, "a" => 1 }, mutation: true)
    second, = prepare(
      { "envelope" => base.merge("deadline_ms" => 9_000, "correlation" => { "session_id" => "s" }), "a" => 1 },
      mutation: true
    )
    assert_equal first["request_digest"], second["request_digest"]
  end

  def test_supplied_request_digest_is_refused
    error = assert_raises(Kioku::Error) do
      prepare({ "envelope" => read_envelope.merge("request_digest" => "sha256:#{'0' * 64}") }, mutation: true)
    end
    assert_equal "kioku.invalid_request", error.code
  end

  def test_explicit_idempotency_key_is_preserved_and_bounded
    envelope, = prepare({ "envelope" => read_envelope.merge("idempotency_key" => "k-1") }, mutation: true)
    assert_equal "k-1", envelope["idempotency_key"]
    assert_raises(Kioku::Error) do
      prepare({ "envelope" => read_envelope.merge("idempotency_key" => "x" * 129) }, mutation: true)
    end
  end

  def test_unknown_scope_enums_are_rejected
    scope = { "store" => "global", "global_categories" => ["not_a_category"] }
    error = assert_raises(Kioku::Error) { prepare({ "envelope" => { "scope" => scope } }) }
    assert_equal "kioku.invalid_request", error.code
  end
end
