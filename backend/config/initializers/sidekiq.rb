# frozen_string_literal: true

require "sidekiq"

# Redis is internal-only and authenticated. REDIS_URL carries host, port and
# database; REDIS_PASSWORD is supplied separately so the credential does not
# have to be embedded in a URL that gets logged (plan 4.2).
redis_options = {
  url: ENV.fetch("REDIS_URL", "redis://redis:6379/0"),
  # Explicit budgets rather than library defaults: a stalled Redis must surface
  # as a visible enqueue failure, not as a request thread parked indefinitely.
  timeout: 5,
  connect_timeout: 3,
  reconnect_attempts: 2
}

redis_password = ENV["REDIS_PASSWORD"]
redis_options[:password] = redis_password if redis_password.present?

Sidekiq.configure_server do |config|
  config.redis = redis_options
end

Sidekiq.configure_client do |config|
  # The api process only enqueues. One connection per Puma thread is the
  # ceiling it can actually use.
  config.redis = redis_options.merge(size: ENV.fetch("RAILS_MAX_THREADS", 5).to_i)
end
