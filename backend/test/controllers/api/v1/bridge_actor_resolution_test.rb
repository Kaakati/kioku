# frozen_string_literal: true

require "test_helper"
require_relative "../../../integration/support/context_remember_wire"

# O1 — the transport-derived actor is only half derived.
#
# Api::V1::BaseController#current_actor builds Context::Domain::Actor with
# origin_role: nil and installation_key: nil, so Actor#authority is nil. Handing
# that actor to a use case writes authority "" into memory_revisions (whose CHECK
# names the five-value vocabulary) and installation_key NULL into events (NOT
# NULL), so the first HTTP-driven context_remember cannot commit at all.
#
# This was invisible because test/controllers/** never invokes a service — the
# probe renders the actor and returns — while every service test builds its actor
# through Factories#bridge_actor, which supplies both fields. So this case drives
# a real service through the controller.
#
# Plan 6.3: "Pair bridge credentials to an installation and approved roots." The
# pairing is declared as configuration (KIOKU_BRIDGE_INSTALLATION_KEY,
# KIOKU_BRIDGE_ORIGIN_ROLE) rather than read from request text, which is what
# keeps it transport-derived. The two cases below pair the same credential to two
# different origin roles, so an implementation that hard-codes one value fails
# the other.
class BridgeActorResolutionTest < ActionDispatch::IntegrationTest
  include Kioku::Test::ContextRememberWire

  setup do
    @project_key = Kioku::Test::Factories::PRIMARY_PROJECT_KEY
    @paired_installation = installation_key
    @unpaired_installation = seed_installation
    register_project(@project_key)
    @object_key = create_durable_object
  end

  test "should attribute the capture event to the installation the bridge credential is paired to" do
    # Arrange
    payload = remember_body(project_key: @project_key, object_key: @object_key,
                            idempotency_key: "idem-installation-1")

    # Act
    envelope = with_bridge_pairing(installation_key: @paired_installation) { post_remember(payload) }

    # Assert
    assert_equal "success", envelope["status"], detail(envelope)
    event = capture_event_for(envelope.dig("data", "memory_key"))
    assert_equal @paired_installation, event.installation_key,
                 "the capture event must carry the installation the credential is paired to, " \
                 "not #{@unpaired_installation.inspect} and not NULL"
    assert_equal event.installation_key, owning_installation_of(envelope.dig("data", "memory_key")),
                 "the capture event and the memory's owning scope must belong to one installation"
  end

  test "should record user authority when the bridge credential is paired to the user origin role" do
    # Arrange
    payload = remember_body(project_key: @project_key, object_key: @object_key,
                            idempotency_key: "idem-authority-user")

    # Act
    envelope = with_bridge_pairing(installation_key: @paired_installation,
                                   origin_role: "user") { post_remember(payload) }

    # Assert
    assert_equal "success", envelope["status"], detail(envelope)
    memory_key = envelope.dig("data", "memory_key")
    assert_equal "user", envelope.dig("data", "authority")
    assert_equal "user", revisions_for(memory_key).first.authority
    assert_equal "user", capture_event_for(memory_key).origin_role
  end

  test "should record assistant authority when the bridge credential is paired to the assistant origin role" do
    # Arrange
    payload = remember_body(project_key: @project_key, object_key: @object_key,
                            idempotency_key: "idem-authority-assistant")

    # Act
    envelope = with_bridge_pairing(installation_key: @paired_installation,
                                   origin_role: "assistant") { post_remember(payload) }

    # Assert
    assert_equal "success", envelope["status"], detail(envelope)
    memory_key = envelope.dig("data", "memory_key")
    assert_equal "assistant", envelope.dig("data", "authority"),
                 "authority is derived from the credential's origin role, not hard-coded"
    assert_equal "assistant", revisions_for(memory_key).first.authority
    assert_equal "assistant", capture_event_for(memory_key).origin_role
  end

  test "should answer a frozen wire code and write nothing when the bridge credential resolves to no installation" do
    # Arrange
    payload = remember_body(project_key: @project_key, object_key: @object_key,
                            idempotency_key: "idem-unpaired-1")

    # Act
    envelope = with_bridge_pairing(installation_key: nil) { post_remember(payload) }

    # Assert
    code = envelope.dig("error", "code")
    assert_includes Context::Errors::REGISTRY.keys, code,
                    "an unresolvable actor must surface as a frozen kioku.* refusal, not as a " \
                    "bare StatementInvalid 500: #{detail(envelope)}"
    refute_nil envelope["status"], "every response carries the status discriminator"
    assert_equal 0, memory_count, "a write ran with an unresolved actor"
    assert_equal 0, memory_revision_count
  end

  private

  def capture_event_for(memory_key)
    refute_nil memory_key, "no memory was committed, so there is no capture event to inspect"
    revision = revisions_for(memory_key).first
    refute_nil revision, "the memory head has no revision"
    Event.find_by(event_key: revision.author_event_key) ||
      flunk("memory_revisions.author_event_key #{revision.author_event_key.inspect} resolves to no event")
  end

  def owning_installation_of(memory_key)
    Scope.find_by(scope_key: memory_record(memory_key).scope_key)&.installation_key
  end

  def detail(envelope)
    "HTTP #{response.status} #{JSON.generate(envelope)[0, 600]}"
  end
end
