# frozen_string_literal: true

# Two separate concerns, both required by the contract's "content- and
# credential-redacted" rule.
#
# Credentials must never reach a log line. Remembered bodies, evidence excerpts
# and dispute reasons are user and source content: they are the thing Kioku is
# trusted to hold, and a debug log is not an authorized destination for them.
#
# Deliberately not filtered: project_key, task_key, memory_key, request_id and
# idempotency_key. They are the handles an operator needs to trace a request,
# and they carry no content. A blanket /_key/ pattern would remove them.
Rails.application.config.filter_parameters += %i[
  passw secret token _token crypt salt certificate otp
  authorization bridge_token

  body content snippet excerpt text reason rationale tradeoffs
  objective summary statement message closing_note
]
