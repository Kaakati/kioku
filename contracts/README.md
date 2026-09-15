# contracts/ — the shared kioku.tool.v1 artifact

One machine-readable definition of the wire contract, read by both deploy units. Before
this existed there were two hand transcriptions of `contracts.json` — a Ruby DSL in the
host package and Ruby classes in the Rails core — that nothing could diff. They had
already drifted seven ways. See `DECISIONS.md`.

**The rule: nobody transcribes this by hand.** If a Ruby constant restates an enum, a
bound, a required list or an error's status, it is a bug, and the conformance suite is
there to make it a failing one.

## Layout

```
contracts/
  README.md                       this file
  DECISIONS.md                    D1-D7, resolved, with the reasoning
  bin/kioku-contracts             sync | verify | digest
  lib/kioku_contracts*.rb         build tooling (not mirrored, not contract data)
  v1/
    contract.json                 version policy, status enum, digest rule,
                                  core-derived fields, closure rule, loader rule
    common.schema.json            every shared enum and object shape, once
    envelope.request.schema.json  the common request envelope (read / mutation)
    envelope.response.schema.json the common response envelope
    errors.json                   the 20 wire names -> status, retryable, HTTP status
    implemented.json              build state: what this build actually accepts
    tools/context_*.schema.json   the six tool input schemas
    conformance/
      envelope_request_cases.json   golden request cases, both sides
      envelope_response_cases.json  golden response cases, both directions
      tool_input_cases.json         golden tool-argument cases, both sides
      resolved_tools.json           GENERATED: each tool resolved and pruned
    MANIFEST.json                 GENERATED: per-file sha256 + artifact digest
```

JSON Schema 2020-12. `$ref` is used in exactly two forms — a local `#/$defs/x` and a
`common.schema.json#/$defs/x` — and sibling keywords apply alongside the referenced schema
with `required` unioned, which is how a mutating tool adds `idempotency_key` and
`request_digest` to the common envelope without restating its properties.

These files are data. None of them is Ruby, and none of them may become Ruby.

## How each side gets them

Neither deploy unit can read this directory at runtime. The backend image's build context
is `./backend`, so nothing above it can be `COPY`ed; the host adapter installs
`context-mcp` and `contextctl` on `PATH` outside the checkout. So each unit carries a
**generated, committed mirror** inside its own boundary:

| unit | mirror | reached by |
|---|---|---|
| backend | `backend/lib/context/contracts/schemas/v1/` | `Context::Contracts` |
| host | `integration/claude/lib/kioku/contracts/v1/` | already on `$LOAD_PATH` via `bin/*` |

The backend path is the one plan §4 already specifies and the one
`backend/config/application.rb:40` already excludes from autoloading —
`config.autoload_lib(ignore: %w[assets tasks context/contracts/schemas])`. That entry named
a directory that did not exist; it is now accurate, so **application.rb needs no change**.
(`autoload_lib`'s ignore list is relative to `lib/`, so `lib/context/contracts/schemas` is
covered, and Zeitwerk ignores non-`.rb` files regardless.)

Duplicating the files is safe only because the copies are machine-checked:

```
contracts/bin/kioku-contracts sync      # regenerate derived files + both mirrors
contracts/bin/kioku-contracts verify    # non-zero and a named list if anything drifted
```

`verify` fails on a stale `resolved_tools.json` or `MANIFEST.json`, on any mirror file that
differs from the source by a byte, on a file present in one tree and not the other, and on
any request schema that declares a core-derived field without a recorded exemption. Run it
in CI and as a pre-commit hook.

## What each side does with them

Each unit writes a thin loader (~40 lines) that resolves `$ref`, prunes by
`implemented.json`, and hands back a schema. Two loaders is one transcription risk, so the
tooling writes the fully resolved and pruned result for all six tools to
`conformance/resolved_tools.json`, and both loaders must reproduce it exactly.

- **Host.** `Kioku::Mcp::Schemas` publishes `resolved_tools.json` verbatim as each tool's
  MCP `inputSchema`; `Kioku::Mcp::Validators::*` take their permitted keys, enums and
  bounds from the same schema; `Kioku::Errors` is built from `errors.json`;
  `Kioku::Envelope::*` take their patterns and bounds from `common.schema.json`. The
  hand-written `lib/kioku/mcp/schemas/*.rb` and `vocabulary.rb` go away.
- **Core.** `Context::Contracts::EnvelopeDecoder` validates against
  `envelope.request.schema.json`; `Context::Errors` is built from `errors.json`;
  `Context::Serialization::Response` renders against `envelope.response.schema.json`.

Refusals stay hand-written on both sides, because a generic schema validator cannot produce
`kioku.project_binding_unresolved` or `kioku.evidence_required` — the artifact records
which condition maps to which wire name in each schema's `x-kioku-refusals` block, and the
conformance cases pin the mapping.

## Enforcement

Four test classes per side, all reading the unit's own mirror. Each case in the fixture
files carries a `why` and a `red_today` list naming the side that fails it at commit
`d86b4a7`, so a case that cannot go red is visible as one.

1. **Error registry parity** — the side's error table must equal `errors.json`: same set of
   wire names, same status, same retryable, and on the core the same HTTP status. Flip
   `kioku.queued.retryable` anywhere and this goes red.
2. **Envelope request conformance** — every case in `envelope_request_cases.json` driven
   through the side's *real* parser (`Kioku::Envelope::RequestParser`,
   `Context::Contracts::EnvelopeDecoder`). Same outcome, same wire code, both sides.
3. **Envelope response conformance** — `envelope_response_cases.json` read both ways: the
   core asserts its serializer *produces* the golden wire object; the host asserts its
   parser *accepts or refuses* it as declared.
4. **Tool input conformance** — `tool_input_cases.json` through each side's real
   validators, plus, on the host, a deep-equality assertion that the published MCP
   `inputSchema` for each of the six tools **is** `resolved_tools.json`.

Plus one cross-tree test in the host suite — the only suite that runs in the repository
working tree — asserting both mirrors are byte-identical to `contracts/v1/`. The backend
suite runs inside the container with only `./backend` mounted and cannot see the source; its
protection is that its fixtures come from its own mirror, so a stale mirror makes its cases
disagree with the host's and the cross-tree test names the file.

## Changing a contract

1. Edit under `contracts/v1/`. Nowhere else.
2. Add or amend a conformance case that goes red before the change and green after.
3. `contracts/bin/kioku-contracts sync`.
4. Run both suites.

A change made only in one side's Ruby fails that side's conformance test, because its Ruby
no longer matches the artifact. That is the whole point.
