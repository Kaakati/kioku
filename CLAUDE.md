# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project state: design-stage, no code yet

The entire repository is one document:

- `docs/claude-code-local-memory-research_v1.md` (~1,108 lines) — "Evidence-Guided Memory and Problem Solving for Claude Code", the architecture and research basis for **Kioku**.

There is no source code, build system, test suite, package manifest, or git repository yet. **There are no build, lint, or test commands.** Do not invent them or claim to have run them. Work here currently means editing or extending the design document.

When implementation starts, the document specifies the eventual toolchain: a Cargo workspace for the Rust crates, Docker Compose for the core + UI containers, and a native `contextctl doctor` command for environment checks. Nothing about that exists on disk yet.

## Windows environment gotchas

- **The Bash tool cannot see `H:\`.** `ls`/`find` against `H:/Kioku` return empty with no error. Use PowerShell (`Get-ChildItem`) or the Read/Write/Edit tools with absolute Windows paths (`H:\Kioku\docs\...`). A "no files here" result from Bash on this drive is a false negative, not an empty directory.
- The design targets **Claude on macOS or Linux/WSL** with a host Unix socket bridge. Windows is the authoring machine, not a supported deployment target. Don't rewrite the design toward Windows-native assumptions unless asked.

## What the system is

A local application giving Claude Code durable memory, code grounding, solution discovery, and scoped verification through **one evidence model**. The central thesis: retrieval quality and bookkeeping are deterministic work that belongs outside the model; interpretation and candidate generation belong to the model; material uncertainties get resolved by new observations, not by more reflection.

The system optimizes **successfully completed tasks with fewer unsupported claims and less repeated investigation** — then minimizes tokens and time within that constraint. Token reduction is never the primary objective.

## Architecture (as designed)

| Component | Runtime | Responsibility |
|---|---|---|
| `contextctl` | Native Rust CLI | Hook dispatch, operator commands, bounded JSON transport |
| `context-mcp` | Long-lived native Rust process | Six MCP tools over stdio |
| `context-agent` | Persistent native Rust service | Approved roots, source manifests, file watching, host validation, durable spool |
| `context-core` | Rust container | Canonical ledger, task state, retrieval, evidence assessment, jobs, API |
| Management UI | Next.js/shadcn container | Task workspace, memory management, evidence inspection, operations |

Transport: CLI and MCP reach the host agent over a **private host Unix socket** (stays on the host, not shared across Docker Desktop's VM boundary); the agent uses authenticated connections to the core on loopback. Proposed ports: `127.0.0.1:7310` (core bridge), `127.0.0.1:7311` (UI).

Hard constraints on the hook path: hooks never invoke `docker exec`, launch a model, run a parser, or scan the repository. The UI can stop without interrupting Claude integration. Latency-sensitive control messages stay separate from bulk object transfer.

Library baseline: `rmcp`, `rusqlite`, Tree-sitter, bounded Rayon pool, `notify`, `ignore`, `gix`, BLAKE3 — all version-pinned. SQLite is the default store; a dedicated vector or graph engine requires a measured workload the baseline fails to serve.

## Storage ownership

| Store | Contents | Durability |
|---|---|---|
| `memory.sqlite` | Identities, events, evidence metadata, memory revisions, task contracts, candidates, checks, disputes, receipts | **Canonical**; WAL + `synchronous=FULL` |
| Repository code databases | Symbols, occurrences, lexical chunks, typed edges, coverage | Rebuildable; WAL `NORMAL` acceptable |
| Content-addressed objects | Retained source, test reports, handoffs, permitted tool output | Durable bytes before any public evidence reference |
| Optional vector indexes | Embeddings, ANN structures | Derived; replaceable generation manifests |
| Host spool | Unacknowledged events, pending uploads | Bounded replay queue; not an editable memory store |

One writer owns each database. Parsing, ranking, source I/O, and model work happen **outside** write transactions. There is no cross-database atomicity claim — canonical changes commit with their outbox jobs; derived transactions publish separately and record receipts. A durable host enqueue means "queued"; only a canonical commit reports "saved".

Schema excerpts live in Appendices A (canonical ledger), C (repository index), D (task/verification), E (retrieval and completion contracts).

## Interfaces

Six MCP tools, versioned and bounded: `context_search`, `context_fetch`, `context_related`, `context_remember`, `context_feedback`, `context_task`. `context_task` uses a discriminated operation schema (`get`, `set_contract`, `record_claim`, `propose`, `plan_check`, `assess`, `checkpoint`, `close`) — it is deliberately not an arbitrary command or SQL interface. Resist adding a seventh tool; `recall`, `who_calls`, and `why` are use cases of search/related/fetch.

Eleven hook events from `SessionStart` through `SessionEnd`, one dispatcher per event, qualified against a capability matrix for the installed client. Hook clients read bounded stdin, reserve stdout for event-specific output, and put diagnostics on stderr. The MCP process reserves stdout for protocol messages.

Context delivery is **pull-first**: the automatic capsule carries changed task state, up to three applicable constraints, and the most consequential unresolved check. Zero additional content is a valid ordinary-turn result. Ceiling for all automatic additions in one user turn: ~1,200 estimated tokens.

## The invariants that govern every design decision

These are the spine of the document. Proposals that violate them are wrong even when they look like simplifications:

- **A record can be authentic and still be wrong.** The ledger is authoritative about what was accepted and when, never about behavioral truth.
- **Six dimensions stay distinct** — authority, lifecycle, availability, applicability, claim support, coverage. Never collapse them into one "verified" boolean or an uncalibrated confidence float.
- **Evidence lineage is not independent confirmation.** Three agents repeating one summary are one source. Never convert a count of endorsements into a probability of correctness.
- **A passing check supports only the cases that actually ran.** Exit zero with no intended cases executed cannot satisfy a behavioral criterion. Record failed, skipped, timed out, interrupted, infrastructure-error, and unknown states separately.
- **The core proposes and records checks; it never gains default power to execute repository commands.** Verification adapters normalize observations that authorized tools already produced. An agent cannot manufacture `pass` by supplying the label.
- **Criteria cannot be deleted to achieve completion.** Contract changes use expected-revision checks and preserve the prior definition and its observations. User requirements stay distinct from agent-inferred criteria.
- **Revisions are immutable.** Supersession preserves history; privacy deletion is a separate operation with tombstones. Low retrieval frequency never auto-erases constraints or negative knowledge.
- **Source validation establishes what was observed at that instant** — not that the file stays unchanged or that extraction was complete. Return coverage and generation vectors; say "known callers within indexed coverage".
- **Identity is observed, never inferred.** No deriving agent identity from PID, timing, model, or "most recently started subagent". Leave attribution unresolved when the join cannot be established.
- **Imported external material stays external evidence.** It cannot override active instructions or become a user correction.

## Implementation sequence

Phases 0–6 with exit evidence per phase (§17): foundation/baseline → durable continuity → source-grounded retrieval → solution loop → awareness and UI → release qualification → conditional extensions.

Task contracts and outcome capture arrive **early**, before a sophisticated graph. Optional inference (embeddings, ANN, rerankers, LSP/SCIP resolvers, extra critique agents) comes last and one at a time, each gated on measured incremental benefit on held-out tasks against its full latency, complexity, and token cost. §15 lists the adoption gate per extension.

Initial latency targets (§15): ≤25 ms p95 event to durable spool, ≤50 ms p95 warm query, ≤100 ms p95 ordinary prompt hook against a 150 ms deadline, 500 ms startup/recovery deadline. Finding and validating a solution is explicitly *not* expected to fit the hook deadline.

## Editing the research document

Match the existing register — it is deliberate and the hardest thing to preserve:

- **Claims are calibrated.** Research findings are described as evidence for mechanisms, not measured results for this implementation. Performance numbers are labeled proposed engineering targets. Phrases like "not established", "requires qualification", "is a proposal" are load-bearing, not hedging noise.
- **Every external claim carries a footnote** (`[^n]`) resolving to the `## Sources` section, with author, linked title, date where relevant, and a short note on what the source establishes.
- Each cited method gets both its **architectural use and its limit** — see the §2 table. Do not add a source without stating what it does not prove.
- Structure is tables and short declarative paragraphs; Mermaid for flow diagrams; SQL for schema excerpts. Sections are numbered, appendices lettered.
- Comparators (Claude-Mem, Context Mode, RTK, Serena, Zep/Graphiti, Aider) are evaluated independently. "Installing all of them together is not the architecture."
