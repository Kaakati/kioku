# frozen_string_literal: true

# Base class for Kioku's persistence models.
#
# Models define associations, invariants that face the database constraints and
# small persistence behaviour. Use cases live in Context::Services (Plan §4.1),
# so no model here carries workflow callbacks or external I/O.
class ApplicationRecord < ActiveRecord::Base
  primary_abstract_class
end
