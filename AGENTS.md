# mushpi-ops — Release & Packaging

This repo is the **release/packaging layer** for the Mushroom Pi system. It owns the container build, the compose service definition, the release manifest, and the publish workflow. It publishes the single image `ghcr.io/mushroom-pi/mushpi` — the server API and the built React dashboard on one port.

It is **not a runtime tier** and contains no application code. The orchestration root (its sibling directory) owns the agent definitions, the full-stack architecture context, and the cross-repo contracts. The sub-repos — `mushpi-server`, `mushpi-client`, `mushpi-grow`, `mushpi-mock`, `mushpi-docs` — are sibling git repos, never vendored here.

On-demand gotchas for editing this layer live in [`REFERENCE.md`](./REFERENCE.md). The **operator-facing** deployment guide lives on the published documentation site (`github.com/mushroom-pi/mushpi-docs` — its `deployment/` pages, with remote access under `configuration/`); this repo keeps release-repo notes in [`DEPLOYMENT.md`](./DEPLOYMENT.md) and the packaging and release process in [`MAINTAINING.md`](./MAINTAINING.md).

## Map

| Path | What exists there |
|---|---|
| `.github/workflows/publish.yml` | CI: on push to `main` or a `v*` tag, checks out the sub-repos, runs the tag⇔manifest guard and the parity check, builds and pushes the image to GHCR via `./.github/actions/build-image` |
| `.github/workflows/publish-dev.yml` | CI (manual `workflow_dispatch` only): dev/pre-release build of the same image with a required free-form `image_tag` plus an automatic `dev-sha-<short>` tag; skips the manifest guard and parity check; never moves `latest` |
| `.github/actions/build-image/action.yml` | Composite action — the mechanical build/push (QEMU, Buildx, GHCR login, metadata, build-push) shared by both publish workflows; carries no trigger, guard or tag policy (see `REFERENCE.md`) |
| `Dockerfile` | Three-stage build (client → server → runtime); build context = this repo's root |
| `docker-compose.yml` | Compose service that pulls `ghcr.io/mushroom-pi/mushpi` (tag from `MUSHPI_IMAGE_TAG`, default `latest`); persists host dir `MUSHPI_DATA_DIR` (default `./mushpi-data`) at `/data` |
| `docker-compose.override.yml` | Local build toggle — **untracked by design**, absent from clones |
| `.dockerignore` | Build-context exclusions |
| `.gitignore` | Ignore-all-then-allowlist; the tracked set is exactly the packaging layer |
| `LICENSE` | MIT — the packaging layer's licence, matching the application repositories |
| `.env.example` | Env template (`PICO_ANNOUNCE_SECRET` required; optional `MUSHPI_DATA_DIR`, `MUSHPI_IMAGE_TAG`, `APP_HTTPS_ENABLED`, the opt-in rate-limit pair `MAX_REQUESTS`/`MAX_REQUESTS_TIME`, and app overrides) |
| `release.json` | Release manifest: `release`/`server`/`client`/`firmware` SemVer plus integer `api_version` |
| `scripts/verify-release.sh` | Release-consistency check: tag⇔manifest, manifest⇔committed component versions, spec versions |
| `scripts/docker-entrypoint.sh` | Container entrypoint (baked into the image): starts as root, creates `/data` plus its `images`/`logs` subdirs, ensures they are owned by `node:node`, drops privileges with `setpriv`, then `exec`s the CMD as the `node` user; fails loudly if run unprivileged and `/data` is not writable |
| `DEPLOYMENT.md` | Release-repo notes plus a pointer to the published operator guide — the operator-facing procedures (provisioning, self-hosting, first boot, Pico setup, updates, backup, remote access) now live on the documentation site, `github.com/mushroom-pi/mushpi-docs`. Human register |
| `MAINTAINING.md` | Maintainer guide — packaging and the release process (human register) |
| `README.md` | Repo entry point for self-hosters, pointing at the published guide |
| `AGENTS.md` | This file — always-loaded agent core |
| `REFERENCE.md` | On-demand agent gotchas for this packaging layer |

## How a build gets its siblings

Sub-repos are **never vendored** into this repo. CI materializes them from GitHub at **default-branch HEAD**: always `mushpi-server` and `mushpi-client` (the build inputs), plus `mushpi-grow` and `mushpi-mock` on tag builds (for the parity check only — firmware never enters the image). The manual dev workflow is the one exception: it accepts per-run `server_ref`/`client_ref` overrides. Locally, the siblings are transient, gitignored clones inside this repo; the clone recipe is in `REFERENCE.md`. The Dockerfile `COPY`s from `mushpi-server/` and `mushpi-client/`, so both must be present for a local build.

## Verification

Run from this repo's root:

- `docker compose -f docker-compose.yml config` — render the base compose file (client-side; no daemon). Re-run with `MUSHPI_DATA_DIR=… MUSHPI_IMAGE_TAG=…` set to verify interpolation.
- `docker compose config` — render with the local override (build mode).
- `bash -n scripts/docker-entrypoint.sh` — syntax-check the container entrypoint.
- `docker build .` — requires the materialized siblings `mushpi-server/` and `mushpi-client/`.
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
