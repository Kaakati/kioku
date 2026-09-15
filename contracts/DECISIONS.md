# Contract decisions — kioku.tool.v1

Seven divergences between the host package's Ruby DSL and the Rails Ruby classes. Each is
resolved here, once, with the reasoning recorded so the ambiguity does not have to be
re-argued. The machine-readable form of every decision is in `v1/`; this file says why.

The root cause of all seven is that there was no shared artifact. Two independent hand
transcriptions of `contracts.json` cannot be diffed, so they drifted and nothing failed.
`v1/` is now the single source; the transcriptions are deleted in favour of reading it.

---

## D1 — every error response renders a `status`

**Decision.** `status` is required on every response without exception. The v1 enum grows
from nine values to eleven: the nine of plan §6.1 plus `invalid` and `internal_error`.

| wire code | status |
|---|---|
| `kioku.invalid_request` | `invalid` |
| `kioku.unsupported_schema_version` | `invalid` |
| `kioku.unsupported_operation` | `invalid` |
| `kioku.handle_unresolved` | `unauthorized_scope` |
| `kioku.internal_error` | `internal_error` |

**Sides that change.** Both, and both by reading `v1/errors.json` instead of keeping a
table. The core stops omitting the key (`Context::Serialization::Response`) and assigns a
status to the five codes that had none (`Context::Errors`). The host widens its accepted
status set (`Kioku::Errors`) and keeps requiring the field (`ResponseParser`).

**Why, not the alternatives.**

`contracts.json` contradicts itself here and says so: `response_fields.status` is
`required: true`, while the `kioku.invalid_request` entry says v1 "returns HTTP/MCP-level
error with code kioku.invalid_request and no status field", flags itself as unfrozen, and
proposes adding a tenth value `"invalid"` in v1.1. `open_decisions` repeats the choice.
The `required: true` sentence is the unambiguous one; the errors[] prose is self-described
as a proposal.

The alternative — making `status` conditional on `error.code` — was rejected because it
defeats the stated design. The contract calls status "the single discriminator"; a
conditional field is not single, and a client must then branch on `status || error.code`,
which is exactly the "inconsistent client branching" the contract warns about. It is also
what produced the observed defect: with the field absent, a core 500 and a malformed
request were indistinguishable on the discriminator, and the host reported both as
`kioku.invalid_request` — a model asking for a handle that does not exist was told its
request was malformed.

Mapping the five statusless codes onto existing values was rejected for `internal_error`:
no caller-fault value can carry a core fault honestly, and reporting a 500 as `conflict` or
`unauthorized_scope` is the same lie in a different place. So two values are added, not
one. `handle_unresolved` does reuse `unauthorized_scope`, because not-found and wrong-scope
are deliberately merged into one code and the caller's branch is identical either way
("this is not obtainable"); both merged branches also answer HTTP 404, so nothing is
disclosed on that channel either. There is precedent in the frozen table:
`kioku.project_binding_unresolved` already carries `unauthorized_scope` although it is a
setup problem rather than a permission one.

Taken in v1 rather than deferred to v1.1 because there is no client to break: the two
halves have never exchanged an envelope. Shipping v1 with the known-broken reading and
fixing it in a minor would mean deliberately releasing the defect.

---

## D2 — the schema version is matched on MAJOR

**Decision.** Accept any `kioku.tool.v1[.minor]`. Reject a different major with
`kioku.unsupported_schema_version`. A response carries the core's implemented version, not
an echo of the caller's minor.

**Side that changes.** The core. `Context::Contracts::EnvelopeDecoder` demands string
equality with `"kioku.tool.v1"` and so refuses `kioku.tool.v1.7`. The host is correct.

**Why.** `contracts.json request_fields.schema_version` is explicit: "Rejected with
kioku.unsupported_schema_version if the major does not match a supported contract. Minor
additions are additive-only." Exact equality makes every additive minor release a breaking
one.

Accepting an unknown minor does not widen the accepted surface. Every request object is
closed, so a field a later minor adds is still refused by name with
`kioku.invalid_request` — the caller learns the version was fine and this particular field
is not taken yet, which is more useful than being told to change a version.

---

## D3 — UUIDv7 stays required

**Decision.** `request_id` is a 36-character lowercase UUIDv7. Required, not relaxed.

**Side that changes.** The core. `EnvelopeDecoder` accepts any non-blank string, and
`backend/test/support/kioku_test_factories.rb:50` emits `SecureRandom.uuid`, which is v4 —
so every `request_id` the backend suite exercises would be refused by the host. The factory
is a defect and becomes `SecureRandom.uuid_v7`. The host is correct.

**Why it is genuinely required, rather than over-strict.** Four reasons, in order of
weight:

1. It is the contract's explicit text (`"string (UUIDv7, 36 chars)"`), not an inference
   from a looser statement.
2. It costs nothing. Ruby 3.4 ships `SecureRandom.uuid_v7`; both deploy units are Ruby
   3.4.10. Relaxing the rule buys no caller anything.
3. `request_id` is echoed onto every response and every receipt, and is the join key for
   the audit log. A time-ordered id gives receipts a near-monotonic natural order and
   index locality without a second column.
4. A machine-checkable format is a cheap, early rejection of a caller that is generating
   ids some other way — which is a caller whose uniqueness guarantee is unknown.

Lowercase is pinned deliberately so one id cannot arrive in two spellings and match two
receipts.

---

## D4 — an evidence ref is exactly one of three keys, and an unresolvable ref is not a malformed request

**Decision.** `ref` is a closed object carrying exactly one of `evidence_key`,
`object_key` or `event_key`. A well-formed ref this build cannot resolve is reported per
entry in `data.evidence_rejected` with a named reason; only an empty eligible set fails,
with `kioku.evidence_required`.

**Sides that change.** Both. The host accepts any non-empty object and must tighten. The
core refuses anything but `object_key` with `kioku.invalid_request`
(`remember.rb:114-117`) and must stop: it moves the refusal from the validation path to
the per-entry rejection list.

**Why.** `contracts.json tools.context_remember` names the ref as
`{evidence_key|object_key|event_key}`, and its response shape already has the machinery for
this: `evidence_rejected: [{ref, reason: enum(scope_mismatch|unavailable|deleted|
anchor_invalid|not_found)}]`. Answering `kioku.invalid_request` tells a caller its request
was malformed when the request was exactly what the contract names; the honest answer is
that the link was not eligible, and the caller can see which one and why. Two keys in one
ref stays `kioku.invalid_request` — that is genuinely ambiguous and the core would have to
guess.

---

## D5 — `kioku.queued` is retryable

**Decision.** `retryable: true`.

**Side that changes.** The core. The host is correct.

**Why.** The contract's own entry for `kioku.queued` says "Replay after reconnect returns
the same idempotency receipt." Re-issuing with the same idempotency key and request digest
is therefore not merely safe, it is the mechanism by which a caller learns the commit
outcome. `retryable` means "the caller may re-issue this request", and here it may and
should. The identical reasoning is already applied on both sides to
`kioku.deadline_exceeded`, whose contract entry says the same thing and which both sides
already mark retryable — so marking `queued` false was inconsistent with a decision the
two sides had already agreed on.

`kioku.partial_result` stays `retryable: false`: an identical retry produces the identical
partial result, and the caller should continue with a cursor instead.

---

## D6 — core-derived fields are refused structurally, not by a name list

**Decision.** Delete both name blacklists. One rule replaces them: every object in the
request surface is closed, and an undeclared key at any depth is refused with
`kioku.invalid_request` naming its JSON Pointer. The list of core-derived names survives in
`v1/contract.json` as an assertion **over the artifact** — no request schema may declare
any of them as a writable property — checked by `contracts/bin/kioku-contracts verify` and
by both suites.

**Sides that change.** Both. The host's `Rules.only` closes only the top level; the core's
`CORE_DERIVED_FIELDS` check reads only `request.request_parameters.keys`.

**Why.** Neither list was complete and neither could be. The host checks three names inside
the envelope; the core checks seven at body top level; `{"envelope":{"authority":"user"}}`
passes the core. Any depth-limited check is bypassed by nesting the name one level deeper,
and any depth cap is arbitrary. A recursive runtime name scan is not the answer either,
because `filters.authority` is a legitimate contract-named retrieval predicate — a
blacklist would have to carry path exceptions and would drift again.

Closure subsumes the guarantee and is stronger: it refuses `authority` nested in
`correlation`, and it refuses `priority` too. Three declarations of `authority` remain in
the artifact and each carries a recorded reason: two are retrieval predicates over labels
already stored on rows, and one is the per-criterion provenance that
`task_operations.set_contract` requires as an input — recording which authority a criterion
claims is precisely what lets the core refuse an assistant relaxing a user-authority
criterion. Claiming an authority is not being granted one.

---

## D7 — `context_remember` accepts every optional input the contract names

**Decision.** The published schema is the artifact's schema. `memory_key`, `lifecycle`,
`mandatory`, `rationale`, `tradeoffs`, `valid_from`, `valid_until`, `links`, `derivative`,
`override`, `origin_project_key`, `task_key`, `source_anchor` and `attempt` are all part of
the contract surface. What this build has not implemented is listed in `v1/implemented.json`
and is refused **by name** with `kioku.unsupported_operation` and
`details.reason = "not_implemented_in_this_build"`, never silently dropped.

**Side that changes.** The host. `PERMITTED = %w[envelope kind destination title body
evidence applicability]` with `Rules.only` refuses all fourteen, and the published MCP
schema omits them too. Both now derive from the artifact, so the list cannot drift again.

**Why.** Refusing them was a straightforward transcription error with real consequences:
the published envelope accepts `expected_revision` but no caller could name the memory it
applies to, so appending a revision was unreachable; and `context_remember.override` is the
project-exception variant that CLAUDE.md's first implementation slice needs — a shared
preference plus one project exception — so the slice could not be built.

Separating "what the contract names" from "what this build implements" keeps both honest.
The schema files stay frozen per major version, so their digests are stable;
`implemented.json` is build state and changes every phase. Publishing only the implemented
subset means the surface a model is shown is exactly the surface that will be accepted,
and flipping an entry to `true` is the gate for the phase that implements it: the
conformance case for that property then has to pass end to end.

`override` stays `false` today. There is no project override row yet, so the honest answer
is a named refusal, and the phase that builds the first slice flips it.

---

## Beyond the seven

Three things were settled in passing because the artifact had to say something:

- **A read may not carry idempotency fields.** An idempotency receipt is a durability
  claim; a read produces none, and accepting the field invites a caller to believe a read
  was deduplicated. Both sides currently ignore them on reads.
- **The request digest is recomputed, never trusted.** `contract.json request_digest`
  records the canonicalization and states that the core recomputes over the received body.
  `Kioku::RequestDigest` already implements exactly this rule and has no callers; a
  caller-asserted digest deciding a durability claim is the E1 defect.
- **The idempotency receipt is keyed `(actor_principal_id, idempotency_key)`.**
  `contracts.json` says the key is actor-scoped; `contract.json idempotency_key` now says
  what that means for lookup, so the unique index on the key alone is a recorded deviation
  rather than an unstated one.
