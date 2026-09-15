# frozen_string_literal: true

# Base class for Kioku's Active Record models.
#
# Models carry associations and constraints-facing validations only (plan 4.1).
# The guarantees live in PostgreSQL — check constraints, composite and deferred
# foreign keys, partial unique indexes and the append-only trigger — because a
# Rails validation does not survive a bulk insert, a replayed spool entry or a
# migration backfill. The validations here exist so a caller's mistake surfaces
# as kioku.invalid_request instead of as an unhandled PG exception rendered as
# kioku.internal_error.
class ApplicationRecord < ActiveRecord::Base
  primary_abstract_class
end
