# frozen_string_literal: true

require_relative "../test_helper"

# "Ship ... contextctl doctor. Doctor checks Ruby/provider capabilities, PostgreSQL
# connectivity/version/extensions, ParadeDB index readiness and coverage, Redis/Sidekiq
# connectivity, schema and queue readiness, Docker connectivity, volume ownership, roots,
# report adapters and attribution coverage" [plan §9; Phase 1 "pairing/doctor"].
#
# For an operator command, stdout is the report; diagnostics still go to stderr
# [plan §3 trust-boundary table].
class ContextctlDoctorTest < Minitest::Test
  def doctor(*args)
    Kioku::TestSupport::HostCommand.run("contextctl", "doctor", *args, timeout: 15.0)
  end

  def report
    @report ||= JSON.parse(doctor("--json").stdout)
  end

  def checks
    report.fetch("checks")
  end

  def agent_check
    checks.find { |check| check["name"] == "agent" } ||
      flunk("doctor reported no agent check: #{checks.map { |c| c['name'] }.inspect}")
  end

  def test_should_report_the_agent_as_unreachable_when_no_agent_socket_is_present
    assert_equal "unreachable", agent_check.fetch("status")
  end

  def test_should_name_the_socket_it_could_not_reach_when_the_agent_is_unreachable
    refute_empty agent_check.fetch("detail").to_s.strip,
                 "doctor reported an unreachable agent without saying which socket"
  end

  # An operator command that cannot check a subsystem must not report it healthy.
  def test_should_report_no_subsystem_as_healthy_when_nothing_could_be_contacted
    healthy = checks.select { |check| check["status"] == "ok" }.map { |check| check["name"] }
    contactable = healthy - %w[ruby config]

    assert_empty contactable,
                 "doctor reported unreachable subsystems as healthy: #{contactable.inspect}"
  end

  def test_should_exit_non_zero_when_a_required_subsystem_is_unreachable
    result = doctor("--json")

    assert result.exited?, "doctor never exited"
    refute_equal 0, result.exit_code, "doctor exited successfully with no agent reachable"
  end

  def test_should_write_its_report_to_stdout_rather_than_stderr
    result = doctor("--json")

    refute_empty result.stdout.strip, "doctor wrote no report to stdout"
  end

  def test_should_cover_the_core_subsystems_named_by_the_operations_contract
    names = checks.map { |check| check["name"] }

    %w[agent core database redis].each do |subsystem|
      assert_includes names, subsystem, "doctor does not check #{subsystem}"
    end
  end
end
