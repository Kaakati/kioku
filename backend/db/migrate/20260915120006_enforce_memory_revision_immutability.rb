# frozen_string_literal: true

# Plan invariant 4: "Revisions are immutable. Corrections append attributed
# revisions." Research Appendix A: "Old revisions remain historical; effective
# supersession can be derived from the head and explicit links without rewriting
# their original content."
#
# Three parts of the frozen contract break silently if this rule lives only in
# Ruby: `expected_revision` optimistic concurrency (kioku.revision_conflict),
# context_feedback's requirement that a dispute names "an exact revision, not a
# head pointer", and context_fetch's `as_of_revision` historical read. An UPDATE
# that edits revision 3 in place makes every receipt that cited revision 3
# describe text that no longer exists.
#
# A trigger rather than a revoked privilege because the application role is also
# the role that appends: revoking UPDATE would block nothing it does not already
# have, and a per-role GRANT cannot distinguish an append from an edit. The
# trigger raises instead of returning NULL, because a write that quietly does
# nothing is indistinguishable from a successful edit to the caller.
#
# DELETE is refused here too. Privacy deletion is a separate lifecycle with
# tombstones (plan invariant 4, plan 5.3), not an ordinary DELETE. TRUNCATE is
# not a row-level operation and is unaffected, which is what lets the test suite
# reset between cases.
class EnforceMemoryRevisionImmutability < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL
      CREATE FUNCTION kioku_reject_revision_mutation() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        RAISE EXCEPTION
          'memory_revisions is append-only: revision % of memory % cannot be % (plan invariant 4)',
          COALESCE(OLD.revision, NEW.revision),
          COALESCE(OLD.memory_key, NEW.memory_key),
          lower(TG_OP);
      END;
      $$;
    SQL

    execute <<~SQL
      CREATE TRIGGER memory_revisions_append_only
        BEFORE UPDATE OR DELETE ON memory_revisions
        FOR EACH ROW EXECUTE FUNCTION kioku_reject_revision_mutation();
    SQL
  end

  def down
    execute "DROP TRIGGER IF EXISTS memory_revisions_append_only ON memory_revisions"
    execute "DROP FUNCTION IF EXISTS kioku_reject_revision_mutation()"
  end
end
