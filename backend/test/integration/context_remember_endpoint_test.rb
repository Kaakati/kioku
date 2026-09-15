# frozen_string_literal: true

require "test_helper"
require_relative "support/context_remember_wire"

# B2 — the Rails half of the one complete path.
#
# /api/v1 is an empty namespace (config/routes.rb:11-12), so nothing has ever
# reached Context::Services::Memories::Remember over HTTP. Its service tests
# construct the actor, the envelope and the collaborators by hand; every
# divergence between what the boundary produces and what the service needs is
# therefore invisible. This case drives the real route, the real decoder, the
# real actor derivation, the real service and a real PostgreSQL commit, and
# asserts the frozen response envelope contracts.json specifies for
# context_remember.
#
# The route is POST /api/v1/context_remember. Every tool in the frozen surface
# arrives as a POST whether it reads or mutates, and the six tools are the six
# operations, so the path is the tool name rather than a REST noun invented for
# the occasion.
class ContextRememberEndpointTest < ActionDispatch::IntegrationTest
  include Kioku::Test::ContextRememberWire

  setup do
    @project_key = Kioku::Test::Factories::PRIMARY_PROJECT_KEY
    register_project(@project_key)
    @object_key = create_durable_object
  end

  test "should commit one revision and answer a canonical receipt when a bridge caller remembers a project decision" do
    # Arrange
    payload = remember_body(project_key: @project_key, object_key: @object_key,
                            idempotency_key: "idem-commit-1")

    # Act
    envelope = with_bridge_pairing(installation_key: installation_key) { post_remember(payload) }

    # Assert
    assert_response :success
    assert_equal "success", envelope["status"], failure_detail(envelope)
    assert_nil envelope["error"]
    assert_equal true, envelope.dig("data", "saved"),
                 "the contract returns saved only after canonical commit; #{failure_detail(envelope)}"
    assert_equal 1, envelope.dig("data", "revision")
    assert_equal 1, envelope.dig("data", "head_revision")
    assert_equal "project", envelope.dig("data", "store_kind")
    assert_equal @project_key, envelope.dig("data", "owner", "project_key")
    assert_equal "active", envelope.dig("data", "lifecycle")
    assert_equal "unassessed", envelope.dig("data", "claim_support"),
                 "a save records a conclusion; it never establishes support"
    assert_equal [{ "ref" => { "object_key" => @object_key }, "relation" => "supports" }],
                 envelope.dig("data", "evidence_accepted")
    assert_empty envelope.dig("data", "evidence_rejected").to_a
  end

  test "should persist the memory, its revision and its receipt when the response reports saved" do
    # Arrange
    payload = remember_body(project_key: @project_key, object_key: @object_key,
                            idempotency_key: "idem-commit-2")

    # Act
    envelope = with_bridge_pairing(installation_key: installation_key) { post_remember(payload) }
    memory_key = envelope.dig("data", "memory_key")

    # Assert
    refute_nil memory_key, "the response named no memory_key; #{failure_detail(envelope)}"
    refute_nil memory_record(memory_key), "saved was reported but no memory head exists"
    assert_equal 1, revisions_for(memory_key).count
    assert_equal payload["title"], revisions_for(memory_key).first.title
    assert_equal 1, receipt_count("idem-commit-2")
    assert_equal 1, search_document_count,
                  "the derived search projection is published in the same transaction as the " \
                  "canonical change it projects"
    assert_equal true, envelope.dig("data", "search_document_published")
  end

  test "should echo the request envelope and every always-present response field on a mutation" do
    # Arrange
    payload = remember_body(project_key: @project_key, object_key: @object_key,
                            idempotency_key: "idem-envelope-1")

    # Act
    envelope = with_bridge_pairing(installation_key: installation_key) { post_remember(payload) }

    # Assert
    assert_equal payload.dig("envelope", "request_id"), envelope["request_id"],
                 "request_id is echoed on every response; #{failure_detail(envelope)}"
    assert_equal "kioku.tool.v1", envelope["schema_version"]
    assert_equal payload.dig("envelope", "idempotency_key"), envelope.dig("receipt", "idempotency_key")
    assert_equal payload.dig("envelope", "request_digest"), envelope.dig("receipt", "request_digest")
    refute_nil envelope.dig("receipt", "receipt_id")
    refute_nil envelope.dig("receipt", "committed_at"), "a canonical commit receipt carries committed_at"
    assert_equal false, envelope.dig("receipt", "replayed")
    assert_nil envelope["continuation"], "continuation is reads-only and null on a mutation"
    assert_equal "complete_for_declared_set", envelope.dig("coverage", "state")
    refute_nil envelope["generation_vector"]
    refute_nil envelope.dig("limits", "deadline_at")
    assert_equal [], envelope["warnings"]
    refute_nil envelope["server_time"]
  end

  test "should return the prior receipt marked replayed and write no second memory when the same key and digest arrive again" do
    # Arrange
    payload = remember_body(project_key: @project_key, object_key: @object_key,
                            idempotency_key: "idem-replay-1")
    first = with_bridge_pairing(installation_key: installation_key) { post_remember(payload) }
    replay = payload.merge("envelope" => payload["envelope"].merge("request_id" => wire_request_id))

    # Act
    second = with_bridge_pairing(installation_key: installation_key) { post_remember(replay) }

    # Assert
    assert_response :success
    assert_equal first.dig("data", "memory_key"), second.dig("data", "memory_key")
    assert_equal first.dig("receipt", "receipt_id"), second.dig("receipt", "receipt_id")
    assert_equal true, second.dig("receipt", "replayed")
    assert_equal 1, memory_count, "a replay committed a second memory"
    assert_equal 1, memory_revision_count
  end

  test "should conflict and write nothing when the same idempotency key arrives with a different request digest" do
    # Arrange
    payload = remember_body(project_key: @project_key, object_key: @object_key,
                            idempotency_key: "idem-conflict-1")
    with_bridge_pairing(installation_key: installation_key) { post_remember(payload) }
    diverged = remember_body(project_key: @project_key, object_key: @object_key,
                             idempotency_key: "idem-conflict-1",
                             title: "A different conclusion entirely")

    # Act
    envelope = with_bridge_pairing(installation_key: installation_key) { post_remember(diverged) }

    # Assert
    assert_equal 409, response.status
    assert_equal "conflict", envelope["status"]
    assert_equal "kioku.idempotency_conflict", envelope.dig("error", "code")
    assert_equal 1, memory_revision_count, "a conflicting replay wrote a revision"
  end

  test "should refuse with kioku.evidence_required and write nothing when no supplied evidence object is durable" do
    # Arrange — a well-formed ref whose object was never stored.
    payload = remember_body(project_key: @project_key,
                            object_key: Kioku::Test::Factories::MISSING_OBJECT_KEY,
                            idempotency_key: "idem-evidence-1")

    # Act
    envelope = with_bridge_pairing(installation_key: installation_key) { post_remember(payload) }

    # Assert
    assert_equal 409, response.status
    assert_equal "kioku.evidence_required", envelope.dig("error", "code")
    assert_equal 0, memory_count, "a write with no eligible evidence committed a memory"
    assert_equal 0, receipt_count("idem-evidence-1"), "a refused write left an idempotency receipt"
  end

  test "should refuse the call when no bridge credential is presented" do
    # Arrange
    payload = remember_body(project_key: @project_key, object_key: @object_key,
                            idempotency_key: "idem-unauth-1")

    # Act
    envelope = with_bridge_pairing(installation_key: installation_key) do
      post_remember(payload, token: nil)
    end

    # Assert
    assert_equal 401, response.status
    assert_equal "kioku.scope_denied", envelope.dig("error", "code")
    assert_equal 0, memory_count
  end

  private

  def failure_detail(envelope)
    "HTTP #{response.status} #{JSON.generate(envelope)[0, 600]}"
  end
end
