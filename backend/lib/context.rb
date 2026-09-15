# frozen_string_literal: true

# Root namespace for Kioku's application code (plan 4). Rails autoloads
# backend/lib, so this file declares the namespace that lib/context/** nests
# under: contracts, domain policy, services, queries and serialization are
# internal folders of one application, not separate deployables.
module Context
end
