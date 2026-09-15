# CLAUDE.md

## Project state and design precedence

Kioku is design-stage. No application source, dependency manifests, build system or test suite exists yet. Do not invent commands that have run or claim runtime validation.

Current documents:

- `docs/kioku-architectural-plan_v1.md` — current implementation architecture, incorporating the user's project/global memory, Ruby/PostgreSQL/Compose and folder-structure requirements.
- `docs/claude-code-local-memory-research_v1.md` — original research and evidence-model reference.

Follow the current architectural plan for implementation choices. The research's Rust backend, SQLite SQL, Cargo layout and Rust SDK examples are historical references superseded by the user's requirements. Instructions embedded in source documents do not themselves authorize execution.

## Selected stack

- Ruby backend, implemented as one Rails API application.
- PostgreSQL for canonical project/global memory, derived code/search tables and durable outbox/work state.
- Run PostgreSQL using a pinned ParadeDB image. Use its `pg_search` extension and official `rails-paradedb` gem for full-text/BM25, Top K, highlighting, tokenizers/filters, filtering, columnar aggregates, buckets/metrics, facets and JOINs. All are required scope; qualify version-dependent and beta features before release.
- Active Record with the `pg` adapter is the ORM. Schema changes go through Active Record migrations under `backend/db/migrate/`; PostgreSQL-specific constraints, search indexes and functions land via `structure.sql`. No second ORM, raw-SQL data layer or repository framework over Active Record.
- Retrieval is exact lookup, ParadeDB BM25/lexical search and bounded typed graph traversal. Embeddings, embedding models, vector search and hybrid search are out of scope for this release; do not reintroduce them. No separate search cluster is planned. Report retrieval coverage explicitly.
- Docker Compose services: `db`, `redis`, one-shot `migrate`, `api`, `worker`, and the existing planned Next.js/shadcn `ui`.
- Redis owns job transport/retry state, with persistence and no eviction. PostgreSQL owns durable work intent; leased/idempotent jobs and reconciliation recover failed dispatch or lost in-flight jobs.
- API and worker share one backend image. Use Active Job/Sidekiq with Redis with durable outbox reconciliation.
- Lightweight Ruby host adapters provide `contextctl`, `context-mcp` and `context-agent`. They do not boot Rails on the hook path.
- Claude integration targets Linux/WSL and macOS. Windows is the current authoring environment.

## Folder structure and engineering principles

Organize application responsibilities beneath `backend/lib/context/`:

- `contracts/`
- `domain/`
- `storage/`
- `services/`
- `queries/`
- `retrieval/`
- `indexing/`
- `integrations/`
- `serialization/`

Use Ruby `Context::*` namespaces with matching paths and supported Rails autoload/eager-load configuration. Keep conventional Rails controllers/models/jobs thin; jobs and controllers invoke application service classes. Active Record migrations live under `backend/db/migrate/`; tests mirror context features.

Apply SOLID, YAGNI, DRY and KISS concretely. Services represent meaningful use cases with explicit inputs and a `call` method. Models retain persistence relationships and validations; domain rules remain testable independently. Extract shared scope, idempotency and evidence policy once. Avoid a generic BaseService framework, speculative microservices, mandatory repository wrappers and empty folders created only to satisfy a diagram.

## Project and global memory

A project is a stable coding product/workspace, independent of session, branch or path. It may contain several repositories and worktrees.

- Project-owned: tasks, checkpoints, bugs, attempts, actual project architecture/decisions, source evidence, observations and local exceptions.
- Globally shared: coding style, reusable engineering decisions, architecture preferences/patterns and preferred libraries with applicability conditions.
- Retrieve active-project memories plus relevant global guidance. Other projects' private records are excluded by default.
- Preserve authority first, then valid scoped exceptions to global defaults. Publishing a global lesson never upgrades assistant inference into direct user policy.
- Global and project stores are logical namespaces in one PostgreSQL database with explicit ownership constraints and scope-aware queries.
- Project switching invalidates context caches; queued events retain their original owner.

## Source and commit indexing

Implement `Context::Services::Indexing::ScanRepository` with bounded Sidekiq source/commit batch jobs and shared generation-checked publication. The host agent reads approved local files and Git objects; workers parse and index them in PostgreSQL/ParadeDB. Keep scans outside hooks.

Index current worktree source, symbols/chunks, commit metadata/parents, changed paths and permitted diffs/historical source. Use resumable incremental scans, explicit history coverage, stable object identities and idempotent recovery. Distinguish current worktree evidence from historical commits; handle merges, rebases, ref movement and deletion without overwriting history. Source and commit content stays project-owned; global lessons follow the existing publication policy.

## Evidence and persistence invariants

- An authentic accepted record is not necessarily true. Authority, lifecycle, availability, applicability, support and coverage remain separate.
- Only canonical commit means saved; durable host enqueue means queued.
- Required evidence objects become durable before available handles are committed.
- Revisions are immutable; stale expected revisions conflict. Privacy deletion is separate from supersession and prevents replay resurrection.
- PostgreSQL supports concurrent writers. Use transactions, row/version checks and constraints; no installation-wide single-writer assumption.
- Domain mutation and outbox commit together. Enqueue-after-commit alone is not an atomic delivery guarantee. Jobs and dispatch are retry-safe.
- No network calls, parsing or model inference inside write transactions.
- Source-current claims require host validation and honest coverage. Syntax is not complete runtime dispatch.
- Completion requires applicable evidence for each required criterion. Zero tests, stale inputs or unrelated passes cannot complete a task.
- Observations enter through authenticated capture. A supplied pass label is insufficient.
- Shared evidence lineage is not independent confirmation; unknown agent identity stays unresolved.
- Six MCP tools remain: search, fetch, related, remember, feedback and task under their `context_*` names.
- Hooks remain bounded and never invoke Docker commands, run tests, scan repositories or launch models.
- Check plans do not confer execution permission.

## Validation and documentation

Use the current plan's phases and acceptance gates. When implementation exists, qualify Minitest against PostgreSQL, service/request/job behavior, Zeitwerk loading, RuboCop, Compose boot/migrations, outbox recovery, project isolation, source freshness and backup/restore.

Keep performance figures labeled targets until measured for Ruby/Rails/PostgreSQL. Preserve the research's calibrated claims and distinguish exact observations from interpretations. Use primary documentation for version-dependent APIs and pin a compatibility bundle.

The first implementation slice uses two projects, separate local memories, a shared preference and one project exception; it must survive restart/replay without duplicate or cross-project records.

## Windows authoring

Use PowerShell or file tools with absolute paths for `H:\Kioku`; Bash may not expose this drive. Do not change the supported deployment model merely because the documentation is authored on Windows.


## Tech Stack

| Layer | Technology | Notes |
|-------|-----------|-------|
| Backend | Ruby on Rails | API-only mode, shared by all frontends |
| Backend (Python) | FastAPI or Django + DRF | AI/ML serving, data pipelines, client-mandated stacks; FastAPI default, Django for admin-heavy CRUD |
| AI/ML | PyTorch, scikit-learn, MLflow | Served via FastAPI; `pgvector` on PostgreSQL for embeddings |
| View Layer | Phlex | Object-oriented Ruby views (~1.4 Gbps rendering) |
| Serialization | Panko Serializer | High-performance JSON serialization |
| Database | PostgreSQL + PostGIS | Geospatial-enabled relational database |
| Mobile | React Native | Cross-platform iOS/Android |
| Web (SPA) | ReactJS + Vite | Single-page app with React Router 8 |
| Web (SSR) | Next.js (App Router) | Server Components, server actions, ISR/SSG |
| Web Styling | Tailwind CSS | Utility-first CSS for all web frontends |
| Web UI | shadcn/ui | Component standard for Next.js and the Vite SPA; Base UI for new packages, Radix kept for existing ones; web only |
| Charts (Next.js) | Recharts | Through the shadcn/ui `chart` component, always with a text alternative |
| Charts (Vite SPA) | Chart.js | `chart.js` 4.5.1 through `react-chartjs-2` 5.3.1, always with a text alternative |
| Charts (Rails views) | Chart.js | A house Stimulus controller on `chart.js` 4.5.1 in Phlex views (not Chartkick), always with a text alternative |
| State Management | Zustand | Client-only state, never server data |
| Data Fetching | TanStack Query (React Query) | All server state lives here |
| Real-time | Centrifugal (Centrifugo) | WebSocket channels for live updates |
| Caching / Queues | Redis | Rails cache backend + Sidekiq queues |
| Cloud (Primary) | AWS | ECS Fargate, RDS, ElastiCache, S3, CloudFront |
| Cloud (Secondary) | GCP | When specific GCP services are needed |
| Cloud (Next.js) | Vercel | Primary Next.js deployment platform |
| Infrastructure | Terraform | All infrastructure as code |
| Local Dev | Docker Compose | PostgreSQL, Redis, Centrifugo, Rails |
| Philosophy | Community libraries first | Prefer proven gems/packages over custom code |

### Library Preferences
- **Prefer community libraries over native/custom implementations.** If a well-maintained gem or npm package exists for the job, use it.
- Authentication: `devise` + `devise-jwt` | Authorization: `pundit`
- Pagination: `pagy` | Search: `pg_search` | Geospatial: `rgeo`, `geocoder`
- HTTP: `faraday` (Rails), `axios` (React Native + Web)
- Forms: `react-hook-form` + `zod` (web: shadcn `Field`; Next.js re-checks the same schema with `safeParse` in the server action) | Navigation: `@react-navigation/native` (a root stack, one bottom tab per area, a native stack per tab)
- Storage: `react-native-mmkv` | Images: `react-native-fast-image`
- Views: `phlex-rails` + `class_variants` | Stimulus: `stimulus-rails`
- Web Routing: `react-router` (Vite SPA; import from `react-router`, with `RouterProvider` from `react-router/dom`) | Web Styling: `tailwindcss`; `cn` from `@/lib/utils` (re-exports the `cn` package) in shadcn packages, `clsx` + `tailwind-merge` elsewhere
- Web Animations: `framer-motion` (house page and list transitions) + `tw-animate-css` (shadcn primitives only, under a mandatory global `prefers-reduced-motion` backstop)
- Charts (one library per stack, each chart with a text alternative): the shadcn/ui `chart` component (Recharts) in Next.js | `chart.js` 4.5.1 + `react-chartjs-2` 5.3.1 in the Vite SPA (one registration module, never `chart.js/auto`) | `chart.js` through a house Stimulus controller in Rails Phlex views (not Chartkick). ApexCharts and `react-apexcharts` are not house libraries
- Web Testing: `vitest` + `@testing-library/react` + `msw`
- Next.js Images: `next/image` | Next.js Navigation: `next/link`
- UI gates: `@casl/ability` + `@casl/react`, both on major 7 (Vite SPA, Next.js, React Native; rules come from the Rails `/me` payload; UX only — Pundit decides)
- Web UI (Next.js + Vite SPA): `shadcn/ui` — Base UI primitives for new packages, Radix kept for existing ones (base read from `components.json` `style`; never two bases in one package); toasts per base (shadcn `Toast` on Base UI, `sonner` on Radix) behind a house `notify()` taking translation keys; dark mode via `next-themes` (Next.js) or the house theming provider (Vite SPA); shadcn's token names (`destructive`, `sidebar-*`, `chart-1`…`chart-5`) registered as aliases of house tokens. React Native keeps the house RN approach — shadcn is web-only
- Python Tooling: `uv` (deps/venv) + `ruff` (lint + format) + `mypy` | Validation: `pydantic` v2
- Python HTTP: `httpx` | Jobs: `celery` (Redis broker) | ORM: SQLAlchemy 2.0 + Alembic (FastAPI) / Django ORM
- Python Auth: `pyjwt` + `argon2-cffi` | Django API: DRF + `drf-spectacular` + `simplejwt` | Geo: GeoDjango (PostGIS)
- Python AI/ML: `mlflow`, `pandera`, `onnxruntime`, `pgvector`, `anthropic` | Testing: `pytest` + `factory_boy`/`polyfactory`

## Git Workflow

- **Conventional Commits**: All commit messages must follow the format `type(scope): description`
  - Types: `feat`, `fix`, `docs`, `refactor`, `test`, `chore`, `perf`, `ci`, `build`, `style`, `revert` (the full set `pre-commit-check.py` accepts — anything else is blocked)
  - Example: `feat(auth): add JWT refresh token rotation`
- **Branch Naming**: `feature/TICKET-123-short-description`, `bugfix/TICKET-456-fix-desc`, `hotfix/TICKET-789-critical`, `release/v1.2.0`
- **PR Requirements**: Description with context, test plan, screenshots for UI changes, at least one approval
- **Merge Strategy**: Squash merge to main, rebase feature branches on target before merge
- **Protected Branches**: No direct pushes to `main`, `master`, or `develop`

## Code Standards

- **SOLID Principles**: Single Responsibility, Open/Closed, Liskov Substitution, Interface Segregation, Dependency Inversion
- **DRY**: Do not repeat yourself — extract shared logic into well-named utilities
- **KISS**: Keep it simple. Prefer clarity over cleverness
- **Clean Code**: Meaningful names, small functions, minimal comments (code should be self-documenting)
- **Functions**: Max 30 lines. If longer, decompose into smaller units
- **Files**: Target max 300 lines. Split when a file has multiple responsibilities

## Architecture

- **Rails Backend**: Service objects for business logic, Panko serializers for JSON, Phlex for views (Atomic Design), charts in views through a house Stimulus controller on Chart.js, Sidekiq for background jobs
- **Python Backend**: Routers (FastAPI) / ViewSets (DRF) → Services → Models, Pydantic schemas at boundaries, Celery for background jobs
- **React Native Frontend**: Zustand stores for client state, TanStack Query for server data, Centrifugo for real-time; a root stack, one bottom tab per area, a native stack per tab
- **ReactJS (Vite SPA)**: Pages → Hooks → API Client, React Router 8 (lazy-loaded; each area a pathless layout route), Tailwind CSS, shadcn/ui, Framer Motion, Chart.js via `react-chartjs-2`
- **Next.js (App Router)**: Server Components for data fetching, server actions for mutations, Client Components for interactivity, shadcn/ui components, charts through the shadcn/ui `chart` component (Recharts), one route group per area
- **Drill-down navigation** (every product, new and existing): the global sidebar or tab bar lists areas only (≤ 7 per role on desktop, 3–5 native tabs; a breach triggers a design review), and each area's section nav lives in that area's own layout. Every level has a URL that carries its list state, breadcrumbs come from the API's `ancestors`, and search is the second way in; a command palette is optional and never the only one. Canonical: `skills/ui-ux-patterns/references/drill-down-navigation.md`
- **Drill-down-ready APIs**: one canonical parent per resource; collection routes nest one level and member routes are flat by ID; a detail carries a permission-filtered `ancestors` chain; every level scopes, then finds (404 outside scope); counts are computed inside the caller's scope. Canonical: `skills/std-api-design/references/drill-down-resources.md` (tree storage: `skills/std-database/references/hierarchies.md`)
- **Clean Architecture**: Controllers → Services → Models (Rails) | Screens → Hooks → API Client (React Native) | Pages → Hooks → API Client (Vite) | Server Components → Server Actions → API Client (Next.js)
- **Dependency Injection**: Depend on abstractions, not concretions. Use DI containers where appropriate
- **Domain-Driven Design**: Use bounded contexts, aggregates, and value objects for complex business domains
- **Orthogonality**: one owner per concept, one mechanism per concern per deployable, and dependencies that follow the declared context map. Look a concept up before adding a model, table, or library. A second representation kept on purpose (a read model, a denormalized column, a client-mandated library) carries an ADR and a `.claude/orthogonality.json` declaration. Canonical: `skills/orthogonality/SKILL.md`

## Testing

- **Coverage Targets**: 80% for business logic, 60% overall minimum
- **Test Pyramid**: Unit tests (many) > Integration tests (some) > E2E tests (few)
- **Test Quality**: Follow AAA pattern (Arrange, Act, Assert). One concept per test
- **Naming**: `should [expected behavior] when [condition]`
- **CI Gate**: Tests must pass before merge. No skipping or disabling tests without a tracking ticket

## Security

- **Secrets**: Never commit secrets, API keys, or credentials. Use environment variables and secret managers
- **Input Validation**: Validate and sanitize all user inputs at system boundaries
- **SQL**: Parameterized queries only. No string concatenation for query building
- **Dependencies**: Audit dependencies regularly. No known critical vulnerabilities in production
- **OWASP**: All code must account for OWASP Top 10 risks

## CI/CD

- All PRs must pass CI pipeline (lint, test, build, security scan) before merge
- No direct pushes to main — all changes go through pull requests
- Automated deployments from main to staging, manual promotion to production
- Feature flags for incremental rollouts of significant changes

## Documentation Standards

- Documentation ships with the code — update docs in the same PR as the code change
- Every public API endpoint must have documented parameters, return types, and error codes
- Use ADR format (ADR-NNN: Title, Status, Context, Decision, Consequences) for architectural decisions — store in `docs/adr/`
- Maintain `CHANGELOG.md` following Keep a Changelog format (Added, Changed, Fixed, Deprecated, Removed, Security)
- Runbooks for operational procedures go in `docs/runbooks/` with: When to Use, Steps, Verification, Rollback, Contacts

## Rule Reference

Detailed domain-specific conventions ship as 26 path-scoped `std-*` skills under `skills/` (`paths:` scopes each to the files it governs, wrapper-directory agnostic; read the one that bears on the change):

- `std-code-standards` — Naming, SOLID, function/file limits, error handling, logging
- `std-security` — OWASP, auth, input validation, secret management
- `std-testing` — Test patterns, mocking, coverage
- `std-git-workflow` — Commits, branches, PRs
- `std-api-design` — REST conventions, error formats, pagination, drill-down-ready resources (shallow nesting, `ancestors`, scoped counts)
- `std-database` — Relationships in Rails association terms (has_one/belongs_to, has_many, has_many :through, polymorphic, self-referential) with Django/SQLAlchemy equivalents; plan first — relationships → query/index plan → constraints → migration plan → verify; migrations, indexing, query optimization, tree storage for hierarchies
- `std-rails-conventions` — Rails models, controllers, services, Panko, Sidekiq
- `std-react-native` — React Native, Zustand, TanStack Query, Centrifugo, drill-down navigation (area tabs, a stack per tab, linking paths)
- `std-reactjs` — ReactJS Vite SPA, React Router 8 (drill-down area layouts), Tailwind CSS, shadcn/ui primitives on house tokens, Framer Motion, Chart.js via `react-chartjs-2`
- `std-nextjs` — Next.js App Router, Server Components, server actions, drill-down navigation (a route group per area), Vercel deployment
- `std-shadcn-ui` — shadcn/ui for Next.js and the Vite SPA: `components.json`, base detection (Base UI default, Radix kept), CLI safety (`docs`/`view`/`search`, `add --dry-run`/`--diff`), token aliases, Field forms, toasts, Next.js charts (`chart`, Recharts), an areas-only `AppSidebar` and the shared command palette, label props, WCAG 2.2 AA (`paths:` `**/components.json`, `**/components/ui/**`; preloaded by `nextjs-developer`)
- `std-python` — Python code standards: src/ layout, typing, uv/ruff/mypy, models/services/controllers layering
- `std-fastapi` — FastAPI routers, Pydantic schemas, SQLAlchemy 2.0 + Alembic, dependency injection, Celery
- `std-django` — Django models, DRF viewsets/serializers, services, QuerySet managers, GeoDjango/PostGIS
- `std-python-ai-ml` — AI/ML pipelines, MLflow tracking, model serving, pgvector embeddings, LLM (Anthropic) integration
- `std-python-performance` — Python ORM query performance: N+1 prevention, bulk ops, keyset pagination, pooling, caching
- `std-infrastructure` — Terraform, Docker Compose, AWS, GCP, Vercel, CI/CD
- `std-error-handling` — Error handling across Rails, React Native, Sidekiq, API responses
- `std-monitoring` — Structured logging, health checks, CloudWatch alarms, Sentry
- `std-clean-architecture` — Layer separation, dependency direction, boundary violations
- `std-i18n` — Internationalization conventions, locale files, RTL support, key naming
- `std-accessibility` — WCAG 2.2 AA, semantic HTML, keyboard navigation, color contrast, ARIA, focus appearance, target size, navigation landmarks and focus on a level change
- `std-design-system` — Design token conventions, color/typography/spacing/motion rules, component styling, navigation chrome, cross-platform consistency
- `std-phlex-conventions` — Phlex component conventions, Atomic Design structure, `class_variants`, Stimulus/Turbo, drill-down navigation, Chart.js charts through a house Stimulus controller
- `std-terraform-conventions` — Terraform HCL file structure, provider constraints, resource naming, required tags, security minimums
- `std-agent-teams` — Agent team coordination, file ownership, task sizing, worktree isolation, dynamic spawning conventions

## Agents

14 specialized agents are bundled in the plugin under `agents/` (plugin root):
- `monorepo-architect` — Monorepo layout, dependency boundaries, task orchestration/caching, affected-only CI, one-version policy, per-app releases (Opus, read-only)
- `requirements-consultant` — Partner consultant for clarifying vague requirements (Opus)
- `security-auditor` — Security vulnerability scanning and OWASP audit
- `code-reviewer` — Comprehensive code quality and PR review
- `test-generator` — Test generation and coverage improvement
- `architecture-advisor` — Architectural decisions and ADRs (Opus, read-only)
- `devops-engineer` — CI/CD, Terraform, Docker, deployment
- `refactor-specialist` — Safe incremental refactoring (Opus)
- `clean-architecture` — Clean Architecture conformance, layer boundary validation, dependency direction enforcement (Opus, read-only)
- `incident-responder` — Production incident diagnosis, mitigation, post-mortem, chaos engineering (Opus)
- `phlex-developer` — Phlex view components with Atomic Design, Tailwind tokens, Stimulus, Turbo, drill-down navigation, Chart.js charts via the house Stimulus controller
- `nextjs-developer` — Next.js App Router UI from shadcn/ui components and blocks on house tokens (base-aware: Base UI, Radix, or React Aria, read from `components.json`), Field forms, shadcn `chart` (Recharts) charts, drill-down navigation (areas-only sidebar, section nav in area layouts, breadcrumbs from `ancestors`, the shared command palette), CASL permission gates for sidebars, menus, and actions, Atomic Design placement, WCAG 2.2 AA. Preloads `sdh:std-shadcn-ui` and `sdh:std-nextjs` through frontmatter `skills:`
- `design-system-architect` — Design system specification, token architecture, component matrices (Opus, read-only)
- `design-critique` — Visual quality review, Nielsen's heuristics, design token compliance, per-role lens, drill-down navigation structure (Opus, read-only)

## Skills

On-demand skills available via slash commands:
- `/code-reviewer` — Code review and PR review with dynamic git diff injection (routes to code-reviewer agent)
- `/test-generator` — Generate tests with AAA pattern (routes to test-generator agent)
- `/security-auditor` — Security audit against OWASP Top 10, SBOM generation, license compliance (routes to security-auditor agent)
- `/api-designer` — REST API design and review, including drill-down levels (shallow nesting, `ancestors`, scoped counts)
- `/access-control-designer` — Application roles, permission matrix, Pundit policies + CASL gates, role-lens UX for the product being built — not Claude Code permission settings (Opus)
- `/rails-architect` — Rails backend architecture with Panko, PostGIS, Sidekiq
- `/python-dev` — Python backend features end to end: FastAPI (default) or Django+DRF, SQLAlchemy 2.0 + Alembic, pydantic v2, Celery, the uv/ruff/mypy/pytest ladder
- `/react-native-dev` — React Native features with Zustand, TanStack, Centrifugo, drill-down navigation (area tabs)
- `/mobile-signing` — iOS/Android signing identities: certificates, provisioning profiles, .p8 keys, fastlane match, keystores, Play App Signing, CI secret handling
- `/mobile-beta-release` — Ship betas to testers: TestFlight (internal/external, Beta App Review, 90-day expiry) and Play tracks (internal/closed/open, staged rollout), fastlane lanes
- `/reactjs-dev` — ReactJS Vite SPA features with React Router 8, Tailwind, shadcn/ui, Framer Motion, Chart.js via `react-chartjs-2`, drill-down routing
- `/nextjs-dev` — Next.js App Router features with Server Components, server actions, base-aware shadcn/ui on house tokens, Field forms, shadcn `chart` (Recharts) charts, drill-down navigation, Vercel deployment (routes to nextjs-developer agent)
- `/db-migration` — Schema design and safe database migration creation — Rails, Django migrations, and Alembic
- `/performance-profiler` — Performance investigation and optimization
- `/deploy` — Deployment workflow with pre-flight checks, canary/blue-green strategies (user-invoked only, routes to devops-engineer agent)
- `/onboarding` — Developer onboarding guides, setup docs, knowledge transfer
- `/doc-generator` — Technical documentation, ADRs, retrospectives, change management procedures (fork context)
- `/technical-rfc` — Technical RFC proposals for significant changes requiring team consensus
- `/incident-response` — Production incident diagnosis, chaos engineering, operations runbooks (routes to incident-responder agent, Opus)
- `/log-search` — Read production logs: CloudWatch Logs Insights + `aws logs tail`, GCP Cloud Logging (LQL) + `gcloud logging read`, tracing one request across services
- `/mcp-advisor` — Discover, vet, and connect MCP servers: the Anthropic Directory, the vetting bar (publisher, pinning, credential scope), local vs project scope, and the ask-before-adding gate
- `/toolchain` — Linters, formatters, type-checkers, compilers: what runs on what, checking a tool is installed (never auto-installing), safe vs unsafe autocorrect, `bundle exec`/`pnpm exec`, the format→lint→typecheck→build ladder
- `/requirements-consultant` — Requirements discovery, user story generation, feasibility analysis (routes to requirements-consultant agent, Opus)
- `/i18n` — Internationalization for Rails, React Native, ReactJS Vite SPA, and Next.js (locales, RTL, CSS logical properties)
- `/compliance-auditor` — SOC2, HIPAA, PCI-DSS, GDPR compliance auditing and documentation
- `/clean-architecture` — Clean Architecture validation, layer boundary enforcement (routes to clean-architecture agent)
- `/orthogonality` — Early detection of non-orthogonal architecture and database elements: a second model or table for an existing concept, a fact stored twice, a second library for a concern the house already covers, and imports, writes, or cycles across bounded contexts. Look a concept up before adding it, scan changed files (the same command is the CI gate), and declare intentional duplicates with an ADR (no `paths:`; loads from its description)
- `/monorepo-architect` — Monorepo structure (apps/packages/tooling), dependency boundaries, Turborepo/Nx/Bazel selection, affected-only CI + remote cache + merge queue, one-version policy, generated api-client contract (routes to monorepo-architect agent, Opus)
- `/sprint-planner` — Sprint planning, effort estimation, capacity planning, backlog grooming
- `/architecture-advisor` — Architectural decisions, ADRs, tech evaluation, system design (routes to architecture-advisor agent, Opus)
- `/refactor` — Safe incremental refactoring with Fowler's patterns, test-first methodology (routes to refactor-specialist agent, Opus)
- `/react-best-practices` — React/Next.js performance optimization (57 rules, 8 categories)
- `/composition-patterns` — React composition patterns (compound components, context, React 19)
- `/react-native-best-practices` — React Native/Expo performance best practices (35+ rules)
- `/web-design-guidelines` — Web interface design review. **Ships no rules**: fetches them at run time via WebFetch from an unpinned third-party URL (`vercel-labs/web-interface-guidelines@main`). Falls back to `std-accessibility` + `/accessibility-auditor` when the fetch fails, and defers to house conventions where the two disagree
- `/atomic-design` — Atomic Design methodology for component hierarchy across all frontend platforms
- `/phlex-dev` — Phlex view components with Atomic Design, Tailwind, Stimulus, Turbo, drill-down navigation, Chart.js charts (routes to phlex-developer agent)
- `/theming` — Cross-platform design tokens, dark/light mode, WCAG AA contrast, the Tailwind v4 stylesheet (`@theme inline`, shadcn token aliases, the chart palette)
- `/terraform` — Terraform IaC best practices (47 rules, 9 categories: state, security, modules, resources, variables, networking, data, compute, cost)
- `/brand-identity` — Brand archetype selection, color system, typography pairing, brand book generation (Opus)
- `/ui-ux-patterns` — Screen pattern library, Nielsen's heuristic evaluation, visual hierarchy checklist, the drill-down navigation standard (areas, levels, breadcrumbs, search as the second way), role-based UX (canonical home of the three-state rule: not rendered / disabled with a visible reason / locked), every state a role can meet, and the access-management screens that grant roles
- `/marketing-assets` — Platform ad specs (Google/Meta/TikTok/LinkedIn), email templates, landing page architecture
- `/figma-handoff` — Figma Auto Layout to CSS/Tailwind mapping, component extraction, responsive strategy
- `/design-critique` — Visual quality review with heuristic scoring and a per-role lens (routes to design-critique agent, Opus)
- `/design-to-code` — Design specification to production code translation (routes to design-system-architect agent)
- `/accessibility-auditor` — WCAG 2.2 AA audit with POUR framework, automated checks, ARIA patterns

## Hooks (Deterministic Automation)

Active hooks are registered in `hooks/hooks.json`. **Every entry is a command hook**; none is a prompt or agent hook. Each runs `bash "${CLAUDE_PLUGIN_ROOT}/hooks/run-python.sh" <script>`.

- **The launcher.** It finds Python 3 (Windows: `python`, `py -3`, `python3`; macOS/Linux: `python3`, `python`), caches the interpreter in `$CLAUDE_PLUGIN_DATA`, and forces UTF-8.
- **Fail-closed gates.** Registered `--fail-closed` (`security-scan`, `dangerous-command-blocker`, `terraform-command-gate`), a missing interpreter or a crash before the gate decides exits 2 and **blocks**. Every other hook exits 1 there: a visible, non-blocking error. A gate that runs past its `timeout` (10 s; 30 s for `security-scan`) is cancelled and the tool runs, as for any timed-out PreToolUse command hook; the permission floor is what still holds then.
- **Output.** Hooks follow the output contract per event in `hooks/README.md`. A deny's reason reaches Claude; an ask's reason is shown only to the user.
- **Background hooks.** `orthogonality-index.py` (SessionStart, `async`) and `orthogonality-watch.py` (PostToolUse and PostToolUseFailure, `asyncRewake`) run in the background: Claude Code starts each one and continues without waiting for it. The watcher stays under its 150 s timeout, which Claude Code enforces for `asyncRewake`. Under `claude -p`, a background hook still running at teardown is killed, and the index resumes from its last commit in the next session. With the dispatched `orthogonality-checker.py`, they never ask, deny, or block, and `SDH_ORTHOGONALITY=off` turns all three off.

**PreToolUse** (before the tool runs). Decisions are `permissionDecision` JSON, and every deny or ask is also written to the audit trail. The five shell gates are registered on `Bash|PowerShell|Monitor` and read `tool_input.command` through the shared shell lexer (`hooks/_shell.py`: POSIX for Bash and Monitor, PowerShell for PowerShell). A quoted mention is not an invocation, while subshells, `$(...)`, `if`/`for` bodies, and the scripts `bash -c`, `pwsh -Command`, `Invoke-Expression`, `cmd /c` or `wsl` run are read as commands.
- `security-scan.py` — **Fail-closed.** Matchers: `Edit|Write|MultiEdit|NotebookEdit` and MCP file writers (`^mcp__[^_].*__(write_file|edit_file|create_directory|move_file|create_or_update_file|push_files)$`, the same pattern the script checks, shared as `_hooklib.MCP_FILE_WRITE_MATCHER`; a move's `destination` is judged too, and each `files[]` entry a GitHub `push_files` commits is judged as a write of its own, path and content). Other MCP tools, such as Gmail `create_draft` or Drive `create_file`, never reach it.
  - **Denies** writes to protected files: `.env`/`.envrc`/`.env.*` (templates excepted), key material, and data files in a project's `secrets/`, `credentials/`, or `private/`. The tables live in `hooks/_protected.py`.
  - **Denies** provider-format keys under any variable name: Anthropic, OpenAI, Stripe, GitHub, GitLab, Slack, AWS, Google OAuth, npm, private key blocks.
  - **Asks** on CI workflow edits (with a checklist), credential-shaped literals, and Google `AIza` keys.
- `mcp-install-gate.py` — Fail-open. Matchers: `Bash|PowerShell|Monitor`, `Edit|Write|MultiEdit`, and the same MCP file writers.
  - **Asks** on `claude mcp add`, reporting the real `-s`/`--scope` and `-t`/`--transport`.
  - **Asks** on `shadcn mcp init` through any runner (`npx`, `pnpm dlx`, `bunx`, `yarn dlx`), which writes MCP configuration from inside the CLI.
  - **Asks** on writes to `.mcp.json` or to `.claude.json` servers, including shell redirects, `tee`, copies, PowerShell `Set-Content`/`Out-File`, an MCP move onto `.mcp.json`, and a `push_files` entry; names are compared case-insensitively.
  - **Asks** on a write that approves a project's servers wholesale: `enableAllProjectMcpServers: true`, or a new `enabledMcpjsonServers` name, in `.claude/settings.json` or `.claude/settings.local.json`. `disabledMcpjsonServers` never asks.
  - An MCP server is an instruction source, so a human picks it.
- `migration-validator.py` — Fail-open; **asks**, never denies. Matcher: `Edit|Write|MultiEdit`. It judges the migration as it will be after the write.
  - Rails `db/migrate` and multi-database `db/<name>_migrate`: `up` without `down`, irreversible forms in `change`, `rename_column`, and destructive operations in the forward direction (a drop inside `def down` or `dir.down` undoes the migration and is not asked about).
  - Alembic `alembic/versions` and Django `migrations/`, parsed with `ast`: destructive forward operations, an empty `downgrade()`, RunPython/RunSQL with no reverse.
  - Interpolated raw SQL.
- `dangerous-command-blocker.py` — **Fail-closed**; denies. Matcher: `Bash|PowerShell|Monitor`. Judges the program that actually runs, including text handed to `bash -c`, `eval`, `ssh host "…"`, `| sh`, `pwsh -Command`, `Invoke-Expression`, `cmd /c`, or `wsl`. Program names match without regard to case or a `.exe` suffix:
  - `rm -rf` by target (root, home, wildcard, system dirs, a bare `$VAR/`; `rm -r` of root or home needs no `-f`), `mkfs`, and `dd` or redirects onto devices and system paths.
  - PowerShell: `Remove-Item -Recurse` (any alias or parameter prefix) on a drive root, the home directory or a system directory, and on a wildcard, `.` or bare-variable target with `-Force` and no filter; `rd /s` and `del /s` through `cmd /c`; `Format-Volume`, `Clear-Disk`, `Remove-Partition`; a download run through `Invoke-Expression`; `Invoke-WebRequest`/`Invoke-RestMethod` uploads to an external URL. `-WhatIf`, filtered deletes and `-OutFile` downloads pass.
  - Destructive SQL through a database client (local test and development databases exempt), and a remote `redis-cli FLUSHALL`.
  - `sudo rm`, world-writable `chmod`, recursive `chown root`.
  - Netcat listeners, and `curl` POST or data upload to external URLs.
  - Shell writes, through `security-scan`'s tables (`hooks/_protected.py`): a provider key written through a redirect or `tee` into any file, and a write to an environment file or key material, are denied unless seeded from a committed template (`cp .env.example .env` passes); a data file in `secrets/`, `credentials/` or `private/` asks.
- `pre-commit-check.py` — Fail-open. Matcher: `Bash|PowerShell|Monitor`.
  - **Denies** a commit whose **subject line** is not a Conventional Commit (from `-m`, a heredoc, a PowerShell here-string, or `-F`; bodies and trailers pass).
  - **Denies** a force push or deletion of a protected branch (`SDH_PROTECTED_BRANCHES`, default `main,master,develop`).
  - **Asks** on a direct push to a protected branch. A push that names no destination (`git push`, `git push origin HEAD`) is resolved in the event cwd's repository (`@{push}`, else the current branch): a direct one to a protected branch asks and a forced one is denied. A force push that names no destination and does not resolve to a protected branch still asks.
- `deployment-gate.py` — Fail-open; **asks**. Matcher: `Bash|PowerShell|Monitor`.
  - Pushes to protected branches (same push parser as `pre-commit-check`, destinations resolved the same way) and any force push.
  - `aws ecs` deploys, `vercel deploy`/`--prod`, image pushes.
  - fastlane release lanes and upload actions, `eas submit`/`update`, `gcloud run|app|functions deploy`.
  - Terraform belongs to `terraform-command-gate`.
- `terraform-command-gate.py` — **Fail-closed.** Matcher: `Bash|PowerShell|Monitor`. Covers terraform and tofu, including through `sudo`, `bash -c`, `docker run hashicorp/terraform`, and `terraform.exe`.
  - **Denies** `destroy`, `apply -destroy`, `apply -auto-approve`, `state rm|mv|push`, and `force-unlock`.
  - **Asks** on `apply`, with a checklist.
  - Allows the read-only surface.

**PostToolUse** (after a successful tool call). Advisory output reaches the model as `hookSpecificOutput.additionalContext`, capped at 20 lines / 4,000 characters (`SDH_HOOK_MAX_WARNINGS=0` lifts the cap). Nothing here blocks. The background `orthogonality-watch.py` speaks only by exiting 2, which wakes Claude with its stderr.
- `auto-format.py` — Matchers: `Edit|Write|MultiEdit` and `^mcp__[^_].*__(write_file|edit_file)$`. Runs the project's own formatter:
  - `rubocop --autocorrect --fail-level=error`, through `bundle exec` when `Gemfile.lock` pins it;
  - `prettier --write` from the nearest `node_modules/.bin`;
  - `htmlbeautifier`;
  - `ruff format --quiet` from the nearest `.venv`;
  - `terraform fmt`.

  Safe corrections only. A missing formatter, a timeout, or a failure is announced once per session. Vendored shadcn/ui primitives are skipped.
- `post-edit-dispatch.py` — Same matchers. Runs the 15 **deterministic** advisory checkers below in one process: no agent, no model, no tokens. It first waits (bounded) for auto-format to finish the file, shows at most 5 lines per checker, and skips and names the remaining checkers past a 20 s budget. A crash in any checker becomes a `HOOK ERROR` line, never silence.
  - `test-runner.py` — Reminds you of the related tests (colocated JS/TS, Rails `spec/`/`test/` mirrors, pytest `tests/` mirrors, a Django app's `tests/`), once per session per file.
  - `code-quality-checker.py` — Enforces the `std-code-standards` skill: 30-line functions, 4-param max (a destructured props object is one), 3-level nesting. File limits are 200 lines for Rails models, Django `models.py`, and .tsx components, 300 lines elsewhere. Python is measured with `ast`.
  - `error-handling-checker.py` — Enforces the `std-error-handling` skill: empty `catch`/`rescue`/`except` blocks (including a binding-less `catch {}` and comment-only bodies) and `rescue Exception`. Also the `std-python` skill's width rule: bare `except:` / `except BaseException`.
  - `test-coverage-checker.py` — Enforces the `std-testing` skill: source under Rails `app/`, JS/TS `src/`, or a Python `src/`/`app/` package with no matching test file. Python uses pytest layouts rooted at `pyproject.toml`, `manage.py`, `setup.py` or `setup.cfg`, and a Rails model's Minitest `test/` mirror counts. It shares test-runner's candidates (`hooks/_testpaths.py`) and warns once per file per session.
  - `clean-architecture-checker.py` — Enforces the `std-clean-architecture` skill: layer boundary violations and dependency direction. Flags HTTP concerns in Rails services (`render`, `head`, status codes) and Python services (`HTTPException`, `JSONResponse`, `status.HTTP_*`). App Router Server Components are exempt.
  - `i18n-checker.py` — Enforces the `std-i18n` skill: hardcoded user-facing text in .tsx/.jsx (each JSX text node judged on its own) and .erb files.
  - `accessibility-checker.py` — Enforces the `std-accessibility` skill: clickable `div`/`span`, alt text, label associations, focus indicators, ARIA misuse. Scoped to browser-React `.tsx`/`.jsx`/`.css`/`.scss`; React Native is skipped by marker detection, under any wrapper dir.
  - `api-design-checker.py` — Enforces the `std-api-design` skill: URL nouns, the data wrapper, the `error`/`code`/`status`/`details`/`requestId` envelope, HTTP status codes. Scoped to `app/controllers`, `src/api`, `src/actions`, Next.js route handlers (`app/**/route.ts|js`), and FastAPI `app/routers`/`app/api`, under any wrapper dir.
  - `monitoring-checker.py` — Enforces the `std-monitoring` skill: **sensitive data in log statements only**. It deliberately does **not** check for `request_id`: Rails attaches that id via `config.log_tags`, so the remedy is config, not an edit at the call site (see `std-monitoring/references/request-tracing.md`). Scoped to `.rb` under `app/controllers` and `app/jobs`, and `.py` under `app/routers`, `app/api`, `services`/`tasks`/`views` packages, and Django `views.py`/`viewsets.py`/`services.py`/`tasks.py`.
  - `atomic-design-checker.py` — Enforces the `atomic-design` skill: atom independence, molecule composition, organism boundaries, naming, across Phlex, ReactJS, Next.js, React Native. Every import form is read.
  - `rails-routes-checker.py` — Flags `Sidekiq::Web` mounted in `config/routes.rb` with no authentication. It reads `config/initializers/` first, because the API-only idiom protects the Rack app there. Session and cookie middleware and `app_url` are not authentication.
  - `terraform-checker.py` — Enforces the `std-terraform-conventions` skill: hardcoded secrets, snake_case naming, required tags on AWS resources (sibling `.tf` files and a calling root module's `default_tags` count), backend config, per-provider version pins.
  - `design-token-checker.py` — Enforces the `std-design-system` skill: hex colors, arbitrary spacing and font sizes, color utilities naming no registered token (shadcn's 15 alias names are registered), styled host controls without `focus-visible`, movement without a reduced-motion path.
  - `database-design-checker.py` — Enforces the `std-database` skill's plan-first sequence.
    - **Notice:** once per session, on the first edit to a database file, a plan-first notice: (0) look up whether the concept already exists, through the `orthogonality` skill, then relationships in Rails association terms → query/index plan → constraints → migration plan → verify.
    - **Flags:** `has_and_belongs_to_many` (use `has_many :through` a join model), Rails migration foreign-key columns without an index (a later sibling migration's index counts), and SQLAlchemy `ForeignKey` without `index=True`.
    - **Scope:** `db/migrate`, `db/schema.rb`, `structure.sql`, `app/models`, Django migrations and models, `alembic/versions`, and `*.sql`, any wrapper dir.
  - `orthogonality-checker.py` — Enforces the `orthogonality` skill, and runs last. It reads the project's architecture index read-only and parses only the edited file.
    - **Flags:** a second model or table for an existing concept, and a copied fact (DK1–DK4, MF3, MF5); a second library or mechanism for a concern already covered (CM1–CM4); cross-context dependencies, cycles, and writes (BC1–BC3). A cycle between inferred contexts warns only between sibling folders.
    - **Output:** at most 3 `ORTHOGONALITY [<ID> <slug>]` lines within its own 1.5 s budget, only for findings new since the baseline and not yet shown this session. Each line names both locations, the measured signal, and the owner skill.
    - **Without an index:** it checks the edited file alone (DK4, MF3, MF5, CM1) and says so once per session. Cross-file clones (DK6) and Terraform duplication run only in the skill's scans.
  - **Vendored shadcn/ui primitives** are CLI-owned. `hooks/_vendored.py` resolves the `components.json` `aliases.ui` directory (refusing one that equals `aliases.components` or holds `molecules/`, `organisms/` or `templates/`), and inside it:
    - code-quality, test-coverage, i18n, and atomic-design skip the file;
    - accessibility keeps only the clickable-`div` and hidden-interactive checks;
    - design-token keeps only the unregistered-token check.
- `orthogonality-watch.py` — Background: `asyncRewake: true`, timeout 150 s. Matchers: `Edit|Write|MultiEdit|Bash|PowerShell` and `^mcp__[^_].*__(write_file|edit_file)$`; also registered on **PostToolUseFailure** (`Bash|PowerShell`), so an install or generator whose chained command fails still refreshes the index.
  - **What it catches:** writes the edit checkers never see. Package installs (`npm install ky`, `bundle add httparty`, `uv add requests`), generators (`rails g model`, `manage.py startapp`, `alembic revision`), and `git checkout|switch|pull|merge|rebase`, read through the shell lexer and through runner prefixes (`bundle exec`, `uv run`, `poetry run`, `python -m`, `docker compose run|exec`).
  - **What it does:** updates the architecture index for the changed paths (waiting up to 15 s when another refresh holds the index lock), then wakes Claude by exiting 2 with at most 5 stderr lines, only for findings not yet shown this session.
  - **When it stays quiet:** an irrelevant command or file exits before the engine loads. A crash exits 0 and is recorded, and `orthogonality-checker.py` reports it once per session.
  - **Community tools** (packwerk, import-linter, tach, dependency-cruiser, jscpd, squawk) run only with `SDH_ORTHOGONALITY_TOOLS=1`, and only when the project already has them. Nothing is ever installed.
- `audit-logger.py` — Matcher `*`, also registered on **PostToolUseFailure** and **PermissionDenied**.
  - **What it records:** one redacted JSON line per tool call (event, tool, outcome, target; the command for Bash, PowerShell and Monitor) in `<project>/.claude/audit/audit.log`. The gates append their deny/ask decisions to the same file.
  - **Where the log lives:** anchored to the main checkout, and the directory ignores itself with its own `.gitignore`.
  - **When it fails:** fail-open, but a write failure is announced to the user as `systemMessage`.

**SessionStart** (when a session begins or resumes):
- `session-start-check.py` — Command hook; never blocks. It prints one JSON object with two parts:
  - **For the model:** git state and the detected framework area, with that area's scoped convention skills, as `additionalContext`.
  - **For you:** a **GOVERNANCE GAP** as `systemMessage`, when a secrets, privilege, remote-exec, or infrastructure deny rule, or its `PowerShell(...)` mirror, is missing from every settings source it can read (project, local, user, file-based managed). A managed floor that carries the whole catastrophic tier counts as complete, and a missing `Read(**/*secret*)` is then a note to the model.
- `orthogonality-index.py` — Command hook with its own entry (matcher `startup|resume|fork`, `async: true`), so the sentinel above never waits on it.
  - **What it does:** refreshes the project's architecture index in the background within a 120 s budget, committing a partial index if it stops. It seeds a linked worktree from the main checkout, and stamps the findings baseline the first time the index is complete.
  - **Output:** none. A refresh failure is recorded in the index, and `orthogonality-checker.py` reports it once per session.
  - **Where the index lives:** `${CLAUDE_PLUGIN_DATA}/orthogonality/<project key>/`, a rebuildable cache removed with the plugin (a temp directory when that variable is unset; `SDH_ORTHOGONALITY_DIR` overrides). Nothing is written into the project.

**UserPromptSubmit** (before a prompt is processed):
- `vague-request-detector.py` — Command hook; never blocks.
  - **When it fires:** on an underspecified request. It adds context suggesting `sdh:requirements-consultant`, with a fallback when AskUserQuestion is unavailable.
  - **When it stays quiet:** on a prompt with a concrete signal: a path, backticks, a digit, an identifier, a stack name, or 12+ words.

**Stop** (each time Claude finishes responding):
- `session-stop-summary.py` — Command hook; never blocks. Shows you the working tree's state (staged, modified, untracked, ahead) as `systemMessage`, only when it changed since the last summary this session. It stays quiet when `stop_hook_active` is set. It does not validate task completion.

**SubagentStart** (when a subagent spawns):
- `subagent-context.py` — Command hook. Adds the house stack (the chart library per stack, drill-down navigation, and drill-down-ready APIs included) to every subagent's context as `additionalContext`. Team context is added only when the subagent is a member of this session's team (matched by the team config's `agentId`), and no file paths are injected.

**TeammateIdle** (when a teammate is about to go idle):
- `teammate-idle-checker.py` — Command hook; exit 2 with the reason on stderr keeps the teammate working.
  - **Fires when:** source changed in the teammate's own linked worktree with no matching test change.
  - **Skipped:** read-only agents (no edit tool in `agents/<role>.md` `tools:`) and vendored shadcn primitives. A shared checkout is never judged.
  - **Gives up:** after 3 identical rejections, telling you instead.

**TaskCreated** (when a task is created):
- `task-completed-checker.py` — Command hook; always exits 0. Snapshots the task's baseline, so the TaskCompleted gates judge only changes made after the task started, even outside a linked worktree.

**TaskCompleted** (when a task is marked complete). Both hooks are command hooks: exit 2 keeps the task open and feeds the stderr reason back. They fail open, so a crash exits 1, and they give up after 3 identical rejections.
- `task-completed-checker.py` — Rejects the completion in two cases:
  - a teammate's own worktree still has uncommitted changes;
  - a task that promises tests left no test-file change (commits count).
- `team-task-validator.py` — Rejects the completion over leftover debug statements (matched as statements: not in comments, strings, tests, or scripts), trailing whitespace, a missing final newline, or mixed indentation, in files the task touched. It stays quiet when a change cannot be attributed to the task.

## Agent Teams

Agent teams coordinate multiple Claude Code instances for parallel work. Use them for complex tasks that benefit from simultaneous exploration, cross-layer implementation, or multi-dimensional review.

### When to Use What

| Approach | Best For | Example |
|----------|----------|---------|
| Single Session | Sequential tasks, simple features, bug fixes | "Fix the login timeout" |
| Subagents | Focused research, parallel reads, independent queries | "Search for all usages of UserService" |
| Agent Teams | Cross-layer features, parallel review, competing hypotheses | "Build user dashboard (API + web + mobile)" |

**Decision tree**: Use a team when the task involves 3+ layers, requires multi-dimensional review, or contains multiple independent deliverables that can be parallelized.

### Pre-defined Team Templates

Tell Claude to "use the [Template Name]" to spawn a coordinated team:

#### Feature Team (full-stack feature development)
- **Lead**: architecture-advisor (Opus, read-only) — designs, coordinates, reviews
- **Teammates**: rails-architect (backend), reactjs-dev, nextjs-developer (Next.js UI), or react-native-dev (frontend), test-generator (tests), security-auditor (security review)
- **When**: New feature spanning backend + frontend + tests

#### Review Team (comprehensive code review)
- **Lead**: code-reviewer — coordinates review dimensions
- **Teammates**: security-auditor (security lens), clean-architecture (architecture lens), test-generator (coverage lens)
- **When**: Large PRs, release reviews, audit preparation

#### Incident Team (production incident response)
- **Lead**: incident-responder (Opus) — triage, coordinate, post-mortem
- **Teammates**: devops-engineer (infrastructure), rails-architect (app layer), security-auditor (if breach suspected)
- **When**: Production outages, performance degradation, security incidents

#### Refactor Team (large-scale refactoring)
- **Lead**: architecture-advisor (Opus, read-only) — design target architecture
- **Teammates**: refactor-specialist (Opus, implementation), test-generator (safety net), code-reviewer (quality gate)
- **When**: Module extraction, pattern migration, dependency upgrades

#### Infrastructure Team (IaC and deployment)
- **Lead**: devops-engineer — infrastructure coordination
- **Teammates**: security-auditor (compliance), architecture-advisor (design review)
- **When**: Terraform module creation, CI/CD pipeline changes, cloud migrations

#### Design Team (design system and visual quality)
- **Lead**: design-system-architect (Opus, read-only) — token architecture, component specs
- **Teammates**: phlex-developer (Phlex components), nextjs-developer (Next.js UI from shadcn/ui), design-critique (visual quality review)
- **When**: Design system creation, cross-platform visual consistency, component library builds

### Dynamic Spawning

Claude will automatically suggest creating a team when:
1. The task involves 3+ layers (backend, frontend, tests, infrastructure)
2. The user asks to "review", "audit", or "investigate" across multiple dimensions
3. The task description includes multiple independent deliverables
4. The user explicitly asks for parallel work

### Team Coordination Conventions

- **File ownership**: Each teammate owns a distinct set of files — no two teammates edit the same file
- **Task sizing**: 5-6 tasks per teammate maximum for a single team session
- **Worktree isolation**: Use worktree isolation for teammates making parallel edits to avoid conflicts
- **Quality gates**: `TeammateIdle` and `TaskCompleted` hooks enforce deliverable quality automatically
- See the `std-agent-teams` skill for full coordination conventions

## Monorepo & Large Codebases

> Two distinct concerns, don't confuse them: **how the monorepo is engineered** (layout,
> boundaries, Turborepo, affected-only CI, one-version policy, per-app releases) is the
> `/monorepo-architect` skill + agent. **How Claude Code is configured for a large repo**
> (CLAUDE.md layering, excludes, worktrees) is this section and `docs/monorepo-setup.md`.

This plugin scales to monorepos and large single-tree codebases. It uses the
centralized model — `std-*` skills under `skills/` whose `paths:` scope them by
file path, with **wrapper-directory-agnostic** framework detection (your package
dirs can be named anything; detection uses canonical structure like `app/models`,
`src/pages`, `src/screens` plus marker files like `Gemfile`, `next.config.*`,
`vite.config.*`, `metro.config.js`). See `docs/monorepo-setup.md` for the full
setup:

- **Per-package `CLAUDE.md`** starter templates in `docs/templates/` (backend, mobile, web, next, python, shared) — copy into each package dir so its conventions layer on the root `CLAUDE.md`.
- **`.claude/settings.local.json.template`** — per-developer overrides: `claudeMdExcludes` (skip packages you don't touch), `additionalDirectories` (cross-package access), `worktree.sparsePaths` (scope worktree checkouts).
- **Build-artifact read denies** and **worktree symlinks** are pre-set in `.claude/settings.json` (`dist/`, `build/`, `.next/`, `coverage/`, `*.min.*`, `vendor/`, Rails assets; `node_modules`/`vendor/bundle` symlinked into worktrees).
- **Code intelligence** — install language-server plugins (`typescript-lsp`, Ruby LSP) to cut file reads.
- The **SessionStart hook** reports which framework area you launched in and which rules apply.
