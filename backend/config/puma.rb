# frozen_string_literal: true

# Thread count per worker. This is the same knob that sizes the Active Record
# pool (see config/database.yml), so Puma can never hold more request threads
# than the process has database connections.
max_threads_count = ENV.fetch("RAILS_MAX_THREADS", 5).to_i
threads max_threads_count, max_threads_count

worker_count = ENV.fetch("WEB_CONCURRENCY", 2).to_i
workers worker_count if worker_count > 1

# Published on the host as 127.0.0.1:7310 by Compose; inside the container the
# API listens on 3000 on all interfaces so the ui service can reach it over the
# internal network.
port ENV.fetch("PORT", 3000)
environment ENV.fetch("RAILS_ENV", "production")

pidfile ENV.fetch("PIDFILE", "tmp/pids/server.pid")

if worker_count > 1
  # Eager loading already happens at boot; preloading shares that work across
  # workers instead of repeating it per fork.
  preload_app!

  before_fork do
    ActiveRecord::Base.connection_handler.clear_all_connections!(:all)
  end

  on_worker_boot do
    ActiveRecord::Base.establish_connection
  end
end

# Compose sends SIGTERM on stop; finish in-flight requests rather than dropping
# a caller that is inside its deadline budget.
worker_shutdown_timeout 25

plugin :tmp_restart
