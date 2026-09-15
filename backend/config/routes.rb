# frozen_string_literal: true

Rails.application.routes.draw do
  # Readiness, not liveness: this returns 200 only after database connectivity
  # and schema presence are both confirmed (plan 3.1). Compose and the ui
  # service use it to decide whether the api is usable.
  get "up", to: "health#show", as: :rails_health_check

  namespace :api do
    namespace :v1, defaults: { format: :json } do
      # Tool and operator endpoints mount here as their services land. Routes
      # are added with the controllers that implement them, not ahead of them.
      #
      # Every tool in the frozen six-tool surface arrives as a POST whether it
      # reads or mutates, and the six tools ARE the six operations, so the path
      # is the tool name rather than a REST noun invented for the occasion. This
      # is the route the host agent's loopback bridge posts a capture to
      # (contracts.json envelope.transport_and_actor.path; plan 3.1).
      post "context_remember", to: "context_remember#create"
    end
  end
end
