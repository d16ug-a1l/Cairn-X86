# AGENTS.md

Guidance for AI coding agents working in this repository.

## Project Overview

Cairn is a general-purpose, goal-directed problem-solving engine built on a **Blackboard Architecture** with an explicit **Fact–Intent graph**. Given an origin (start) and a goal (end), it searches for a path through an unknown state space. AI penetration testing / CTF solving is the first validated domain, but the engine defines no roles and no fixed workflows.

Three primitives form the whole model:

- **Fact**: a confirmed, objective finding written to the board. Facts are append-only, never modified; state changes are expressed by adding new facts.
- **Intent**: a declared direction of exploration (an edge between facts), claimed by workers via heartbeat, concluded with a new fact.
- **Hint**: human judgment injected at any time, absorbed by agents on their next read.

Agents coordinate exclusively through the shared board (stigmergy) — no direct communication. Three task types exist, all executed by the same worker:

| Task | Purpose |
|------|---------|
| `bootstrap` | Runs once at project start; attempts to solve the problem directly. Only succeeds when it can also write key proof facts. |
| `reason` | Reads the full graph; decides whether the goal is met, or proposes new intents (max `tasks.reason.max_intents` per step). |
| `explore` | Claims one intent, executes the exploration, reports one fact. |

Full design rationale lives in `docs/specs/server-protocol.md` and `docs/specs/dispatcher-design.md` (written in Chinese — read them before changing protocol or scheduling semantics).

## System Architecture

The repo has four parts:

1. **Cairn Server** (`cairn/src/cairn/server/`) — the protocol source of truth. A FastAPI app that stores Projects / Facts / Intents / Hints in SQLite (`db.py`, default `~/.local/share/cairn/cairn.db`), maintains intent claims/heartbeats/conclusions, and serves a small static UI from `server/static/`. Routers: `projects`, `intents`, `hints`, `export`, `settings`.
2. **Dispatcher** (`cairn/src/cairn/dispatcher/`) — the only writer to the protocol and the control plane. Reads the graph, schedules tasks, picks workers, manages execution, and writes results back. Agents never call the server API themselves.
   - `scheduler/loop.py` — main scheduling loop (`DispatcherLoop`): per-tick project scan, dispatch order (initial → bootstrap → reason-on-change → explore), concurrency caps, cancellation of inactive projects.
   - `tasks/` — per-task-type runners (`bootstrap.py`, `reason.py`, `explore.py`, `common.py`), including two-phase execute → conclude fallback on timeout/parse failure.
   - `workers/` — worker abstraction. `base.py` defines the `WorkerDriver` interface; `adapters/` implement `claudecode`, `codex`, `pi`, and `mock` drivers; `registry.py` maps type → driver.
   - `runtime/` — execution backends: `containers.py` (one Docker container per project) and `local_backend.py` / `local_process.py` (workers run directly on the dispatcher host). Also heartbeat, cancellation, and startup health checks.
   - `config.py` — pydantic models validating `dispatch.yaml`; `prompts/` — markdown prompt templates shipped as package resources (`default` and `mock` groups).
   - `protocol/client.py` — the HTTP client to the server; `contracts.py` + `output_parser.py` — parsing and validation of agent structured JSON output.
3. **Worker container** (`container/`) — Kali-based image (`container/Dockerfile`) with security tooling; published to `ghcr.io/oritera/cairn-worker-container` by `.github/workflows/build-container-ghcr.yml` on pushes to `main` touching `container/**`. Note `container/AGENTS.md` is written in Chinese and is aimed at the in-container agent, not at code contributors.
4. **Top-level packaging** — root `Dockerfile` (builds the cairn package with uv), `docker-compose.yaml` (runs `cairn-server` on port 8000 plus a `cairn-dispatcher` once the server is healthy), and `dispatch*.yaml` example configs.

## Technology Stack

- Python ≥ 3.12, packaged with **uv** (`cairn/pyproject.toml`, build backend `uv_build`, locked via `uv.lock`).
- FastAPI + Uvicorn (server), Click (CLI entry point `cairn`), pydantic (config + API models), PyYAML, `requests` (dispatcher → server), `docker` (container runtime), SQLite (server storage, no ORM — raw SQL in `server/db.py`).
- No JavaScript build; the server UI is a static bundle in `cairn/src/cairn/server/static/`.

## Build and Run Commands

All Python work happens inside `cairn/` (the uv project). From the repo root:

```bash
# Run the test suite (fast, no Docker or live LLM endpoints required)
uv run --project cairn --group dev pytest

# Start the API server (default http://127.0.0.1:8000)
uv run --project cairn cairn serve

# Run the dispatcher against a config
uv run --project cairn cairn dispatch --config dispatch.yaml

# One scheduling iteration, or startup worker health checks only
uv run --project cairn cairn dispatch --config dispatch.yaml --once
uv run --project cairn cairn dispatch --config dispatch.yaml --startup-healthcheck-only
```

Docker Compose path (container execution mode):

```bash
cp dispatch.example.yaml dispatch.yaml   # fill in LLM endpoints/keys
docker compose up --build
```

`dispatch.yaml` is gitignored. Two templates exist:

- `dispatch.example.yaml` — container mode; requires per-worker LLM env keys (`ANTHROPIC_*`, `CODEX_*`/`OPENAI_API_KEY`, or `PI_*`) because workers run inside the container with no host CLI config.
- `dispatch.local.example.yaml` — local mode (`runtime.execution: local`); reuses the host's already-logged-in `claude`/`codex`/`pi` CLIs, no API keys in config. Run the dispatcher directly on the host, not in Docker.

## Testing Strategy

- Tests live in `cairn/tests/`, run with pytest (`testpaths = ["tests"]` in `pyproject.toml`).
- The suite is designed to run **without Docker and without live model endpoints**: heavy dependencies are replaced by fakes defined in `tests/conftest.py` (`FakeClient`, `FakeDriver`, `FakeContainerManager`, `FakeLease`), and the `mock` worker driver simulates agent behavior end-to-end (`test_mock_end_to_end.py`).
- Coverage areas: config validation and adapters (`test_config_and_adapters.py`), scheduler logic (`test_scheduler_logic.py`), worker task runners (`test_worker_tasks.py`), server API (`test_server_api.py`), DB migrations (`test_db_migrations.py`), health checks, local execution, protocol/startup, runtime logic, container archives, contracts/drivers.
- When adding dispatcher behavior, follow the existing pattern: unit-test against the fakes rather than spinning up real containers or calling real LLMs.
- Verified on 2026-09-19: `uv run --group dev pytest` → 98 passed.

## Code Style and Conventions

- `from __future__ import annotations` at the top of modules; type hints throughout; dataclasses (`slots=True`) for runtime state, pydantic models for config and API payloads.
- Dispatcher logging follows a "state-change first" convention (`docs/specs/dispatcher-design.md` point 7): steady-state polling, heartbeats, and repeated skips must not spam; container creation, task dispatch, health checks, timeouts, concludes, releases, and worker unavailable windows must be visible. Use `DispatcherLoop._log_changed` scopes for repeated messages.
- Server-side `intent_timeout` / `reason_timeout` must be greater than the dispatcher `runtime.interval`; the dispatcher validates this on startup.
- Prompts are markdown resources under `cairn/src/cairn/dispatcher/prompts/<group>/` and must contain the placeholders enforced in `config.py` (`DEFAULT_PROMPT_REQUIRED_TOKENS` / `PROMPT_REQUIRED_TOKENS_BY_GROUP`) — adding a prompt group means adding a directory plus the token table entry.
- Single dispatcher instance per server is assumed; multiple dispatchers against one server are unsupported.
- Additive-only facts: never design features that mutate or delete facts — express change as new facts.

## Security Considerations

- This is a security-research tool. Use it only against systems you are explicitly authorized to test (see the disclaimer in `README.md`).
- Never commit real API keys: `dispatch.yaml` is gitignored; examples use placeholders. `common_env` is merged into every worker's environment — treat it as sensitive.
- Local execution mode runs agents with the dispatcher host user's permissions and no sandbox; container mode isolates per project but often uses `network_mode: host` — both assume a trusted environment.
- `container.cap_add` (e.g. `NET_RAW`, `NET_ADMIN`) should only be enabled when a task truly needs packet crafting or network admin.

## Deployment Notes

- Root `Dockerfile` installs dependencies with `uv sync --frozen` against the Aliyun PyPI mirror (also configured as the default index in `pyproject.toml`); keep `uv.lock` in sync when changing dependencies.
- The worker image is built from `container/` and published to GHCR by GitHub Actions; the dispatcher config must point `container.image` at a pulled image.
- Server data persists to `~/.local/share/cairn/cairn.db` (mounted to `./datas/cairn/` in docker-compose).
