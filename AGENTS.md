# mushpi-ops — Release & Packaging

This repo is the **release/packaging layer** for the Mushroom Pi system. It owns the container build, the compose service definitions, the release manifest, and the publish workflow. It publishes two images: `ghcr.io/mushroom-pi/mushpi` — the server API and the built React dashboard on one port, the **hub** image — and `ghcr.io/mushroom-pi/mushpi-mock`, the simulated Pico unit used by the demo stack (see `REFERENCE.md` §Demo stack).

It is **not a runtime tier** and contains no application code. The orchestration root (its sibling directory) owns the agent definitions, the full-stack architecture context, and the cross-repo contracts. The sub-repos — `mushpi-server`, `mushpi-client`, `mushpi-grow`, `mushpi-mock`, `mushpi-docs` — are sibling git repos, never vendored here.

On-demand gotchas for editing this layer live in [`REFERENCE.md`](./REFERENCE.md). The **operator-facing** deployment guide lives on the published documentation site (`github.com/mushroom-pi/mushpi-docs` — its `deployment/` pages, with remote access under `configuration/`); this repo keeps release-repo notes in [`DEPLOYMENT.md`](./DEPLOYMENT.md) and the packaging and release process in [`MAINTAINING.md`](./MAINTAINING.md).

## Map

| Path | What exists there |
|---|---|
| `.github/workflows/publish.yml` | CI: on push to `main` or a `v*` tag, checks out the sub-repos, runs the tag⇔manifest guard and the parity check, then builds and pushes **both** images to GHCR via `./.github/actions/build-image` — the hub job, plus `build-and-push-mock` (builds `Dockerfile.mock`) |
| `.github/workflows/publish-dev.yml` | CI (manual `workflow_dispatch` only): dev/pre-release build of the same image with a required free-form `image_tag` plus an automatic `dev-sha-<short>` tag; skips the manifest guard and parity check; never moves `latest`. **No mock path yet** (see `REFERENCE.md` §Demo stack) |
| `.github/actions/build-image/action.yml` | Composite action — the mechanical build/push (QEMU, Buildx, GHCR login, metadata, build-push) shared by both publish workflows; carries no trigger, guard or tag policy, and an optional `file` input selects the Dockerfile (default `./Dockerfile`, which every hub caller relies on) (see `REFERENCE.md`) |
| `Dockerfile` | **Hub** image — three-stage build (client → server → runtime); the runtime stage carries the server's native-build toolchain plus the container's mDNS resolver and its NSS client; build context = this repo's root |
| `Dockerfile.mock` | **Mock** image — `python:3.12-slim-bookworm` + `uv`, running the mock CLI as UID/GID 1000 so it shares the hub's `/data` ownership; its paired `Dockerfile.mock.dockerignore` **replaces** the hub's `.dockerignore` for this build (see `REFERENCE.md`) |
| `docker-compose.yml` | Hub service — pulls `ghcr.io/mushroom-pi/mushpi` (tag from `MUSHPI_IMAGE_TAG`, default `latest`), runs on the **host network** and persists `MUSHPI_DATA_DIR` (default `./mushpi-data`) at `/data`; the missing `ports:` block is load-bearing (see `REFERENCE.md`) |
| `docker-compose.demo.yml` | Additive **demo stack** — the published hub image plus the mock over a fixed bridge network, loopback-bound by default; the hub compose file is untouched (see `REFERENCE.md` §Demo stack) |
| `docker-compose.override.yml` | Local build toggle — **untracked by design**, absent from clones |
| `.dockerignore` | Build-context exclusions |
| `.gitignore` | Ignore-all-then-allowlist; the tracked set is exactly the packaging layer |
| `LICENSE` | MIT — the packaging layer's licence, matching the application repositories |
| `.env.example` | Env template (hub vars: `PICO_ANNOUNCE_SECRET` required; optional `MUSHPI_DATA_DIR`, `MUSHPI_IMAGE_TAG`, `APP_HTTPS_ENABLED`, the Swagger docs trio, and the opt-in rate-limit pair), plus a marked **demo section** feeding `docker-compose.demo.yml` (see `REFERENCE.md` §Demo stack) |
| `release.json` | Release manifest: `release`/`server`/`client`/`firmware` SemVer plus integer `api_version` |
| `scripts/verify-release.sh` | Release-consistency check: tag⇔manifest, manifest⇔committed component versions, spec versions |
| `scripts/docker-entrypoint.sh` | Container entrypoint — root start, `/data` ownership fix, mDNS resolver start, then privilege drop; detail in `REFERENCE.md` |
| `scripts/demo-stack.sh` | The demo stack's single entry point — resolves the announce secret (file or environment), generates the mock config, runs `docker compose … up`, and verifies the seeded history on the detached path |
| `DEPLOYMENT.md` | Release-repo notes plus a pointer to the published operator guide (the operator-facing procedures now live on the documentation site, `github.com/mushroom-pi/mushpi-docs`). Human register |
| `MAINTAINING.md` | Maintainer guide — packaging and the release process (human register) |
| `README.md` | Repo entry point for self-hosters, pointing at the published guide |
| `AGENTS.md` | This file — always-loaded agent core |
| `REFERENCE.md` | On-demand agent gotchas for this packaging layer |

## How a build gets its siblings

Sub-repos are **never vendored** into this repo. CI materializes them from GitHub at **default-branch HEAD**: `mushpi-server` and `mushpi-client` (the hub build inputs), and now also `mushpi-mock`, which the `build-and-push-mock` job checks out unconditionally as the `Dockerfile.mock` build input. `mushpi-grow` joins them on tag builds for the parity check only — firmware never enters either image. The manual dev workflow is the one exception: it accepts per-run `server_ref`/`client_ref` overrides. Locally, the siblings are transient, gitignored clones inside this repo; the clone recipe is in `REFERENCE.md`. `Dockerfile` `COPY`s from `mushpi-server/` and `mushpi-client/`, and `Dockerfile.mock` from `mushpi-mock/`, so the sibling a given build needs must be present.

## Verification

Run from this repo's root:

- `docker compose -f docker-compose.yml config` — render the base compose file (client-side; no daemon). Re-run with `MUSHPI_DATA_DIR=… MUSHPI_IMAGE_TAG=…` set to verify interpolation.
- `docker compose config` — render with the local override (build mode).
- `docker compose -f docker-compose.demo.yml config` — render the demo stack. Re-run with `MUSHPI_DEMO_HOST`/`MUSHPI_DEMO_PORT`, `MUSHPI_IMAGE_TAG` and `MUSHPI_MOCK_IMAGE_TAG` set to verify interpolation.
- `bash -n scripts/docker-entrypoint.sh scripts/demo-stack.sh` — syntax-check the scripts.
- `docker build .` — requires the materialized siblings `mushpi-server/` and `mushpi-client/`.
- `docker build -f Dockerfile.mock .` — requires the materialized sibling `mushpi-mock/`.
- `bash scripts/verify-release.sh [vX.Y.Z]` — release-consistency check; requires the four siblings present and `jq`.
- `actionlint .github/workflows/publish.yml .github/workflows/publish-dev.yml` — if actionlint is installed. Do **not** pass a `.github/actions/**/action.yml` to it: actionlint parses explicit file arguments as workflows and cannot lint composite actions.

## Conventions

- **Never commit `.env` or `mushpi-data/`.** Both are gitignored; `.env` holds local secrets and `mushpi-data/` holds live runtime state (SQLite DB, uploaded images, logs). `mushpi-data/` is only the **default local path**; when the stack runs elsewhere, the live state sits in the host directory `MUSHPI_DATA_DIR` points at.
- **The `vX.Y.Z` tag and `release.json` change in one commit.** They are an intra-repo pair; keeping them atomic is what makes the tag⇔manifest guard meaningful.
- **The image name is pinned to the product name** (`ghcr.io/${{ github.repository_owner }}/mushpi`), deliberately decoupled from this repo's name. Renaming this repo does **not** rename the published image; changing the image name is a deliberate product decision, not a side effect of a repo rename.
- **A push to `main` or a `v*` tag triggers a publish.** A tag also pins only this repo's files while sub-repos build at default-branch HEAD — push sub-repo release commits first.
- **`MUSHPI_DATA_DIR` / `MUSHPI_IMAGE_TAG` are compose *interpolation* vars** (read from `.env`/the environment, never passed into the container): the host directory bind-mounted at `/data` (default `./mushpi-data`) and the pulled image tag (default `latest`). The in-container layout (`SQLITE_PATH`, `UPLOAD_DIR`, `LOGS_PATH`) is fixed and must not be repointed.
- **Dev builds never move `latest`.** `publish-dev.yml` (manual only) publishes a validated free-form tag plus `dev-sha-<short>`; `latest` and strict `vX.Y.Z` inputs are rejected and `flavor: latest=false` blocks auto-emission. `latest` remains owned solely by `publish.yml`.
- **The shared build action stays dumb.** `.github/actions/build-image` is mechanical build/push only — callers own triggers, guards and tag/flavor policy, and `flavor` is passed explicitly by each caller. Never add ref logic or a release-vs-dev `mode` input to it.
- **Register split:** agent rules live here and in `REFERENCE.md`; **operator-facing procedures live on the published documentation site** (`github.com/mushroom-pi/mushpi-docs` — its `deployment/` pages, with remote access under `configuration/`), while what stays in this repo is release-repo notes in `DEPLOYMENT.md` and the packaging and release process in `MAINTAINING.md`. Do not put agent-directed instructions in the human-named docs, and do not restate them here. All three human-facing files (`DEPLOYMENT.md`, `MAINTAINING.md`, `README.md`) are **docs-tier**: the ops agents' edit permission maps exclude them, so an ops agent flags a needed change for the orchestrator to route rather than editing it.

## ⛔ Data Deletion Prohibition

Inherited from the root `AGENTS.md`. **Never delete, modify, or destroy database data, server state, or live records without the user's explicit consent.** When the stack runs from this directory, `./mushpi-data` — or the directory `MUSHPI_DATA_DIR` names — is live state: the SQLite database, uploaded images, and logs. Investigation is read-only — never exercise destructive endpoints or queries against a running instance. This applies to every agent working in this repo.
