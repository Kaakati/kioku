# frozen_string_literal: true

# Assertions for "the DATABASE refused this write".
#
# The distinction these make is the whole point of the persistence suite. A bare
# `assert_raises(ActiveRecord::StatementInvalid)` also passes when the table does
# not exist yet, which would turn every constraint test into a tautology during
# the red phase. So each assertion inspects the wrapped PG error and fails
# loudly when the refusal came from a missing table, a missing column or a typo
# rather than from the constraint under test.
#
# Callers name the SQLSTATE family they expect (PG::CheckViolation,
# PG::UniqueViolation, PG::ForeignKeyViolation) rather than a constraint name,
# so a write refused by an unrelated constraint of a different kind cannot pass
# for the one under test, and renaming a constraint does not break a test.
module DatabaseRejectionAssertions
  # SQLSTATE class 23 — not-null, foreign key, unique, check, exclusion.
  INTEGRITY_REFUSALS = [PG::IntegrityConstraintViolation].freeze

  # Append-only enforcement (plan invariant 4) can be a trigger, a rule or a
  # revoked privilege; all three are accepted, a silent no-op is not.
  IMMUTABILITY_REFUSALS = [
    PG::RaiseException,
    PG::InsufficientPrivilege,
    PG::RestrictViolation
  ].freeze

  # Runs the block in its own transaction so a refusal does not poison the
  # surrounding test transaction, then asserts the refusal came from `because`.
  def assert_database_rejects(because: INTEGRITY_REFUSALS, describing: nil)
    error = assert_raises(ActiveRecord::StatementInvalid, PG::Error) do
      ActiveRecord::Base.transaction(requires_new: true) { yield }
    end
    cause = error.is_a?(PG::Error) ? error : error.cause
    assert because.any? { |klass| cause.is_a?(klass) },
           rejection_message(because, cause, describing)
    cause
  end

  private

  def rejection_message(because, cause, describing)
    subject = describing ? "#{describing}: " : ""
    "#{subject}expected PostgreSQL to refuse this write with " \
      "#{because.map(&:name).join(' or ')}, but it failed with " \
      "#{cause.class}: #{cause.message.strip}. A missing table, column or " \
      "constraint is a failure of the schema, not a rejection of the write."
  end
end
