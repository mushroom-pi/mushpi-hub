# mushpi-hub — Reference (On-Demand)

Long-tail gotchas for the release/packaging layer. **Load only when the task touches these areas** — do not read on every spawn. The always-loaded [`AGENTS.md`](./AGENTS.md) holds the file map, the sibling-materialization model, verification commands, and core conventions.

Topics covered here: build-context layout · Yarn Berry 4 / Corepack · `better-sqlite3` native build · client API regeneration + `tsc` gate · entrypoint & runtime details · rate limiting (`MAX_REQUESTS` / `MAX_REQUESTS_TIME`) · `release.json` in the build context · tag & CI semantics · dev / pre-release image builds · shared build action · local verify/build prerequisites · host networking (`network_mode: host`) · container mDNS resolver (`.local` names) · `docker-compose.override.yml` & local `.env`.

---

## Build-context layout

- The Docker build context is **this repository's root** (the `mushpi-hub` checkout). The `Dockerfile`, `docker-compose.yml`, `.dockerignore`, `.env.example`, and `.github/workflows/publish.yml` all live here; `COPY mushpi-server/...` and `COPY mushpi-client/...` reach the siblings because they are materialized **inside** this root.
- Never move the `Dockerfile`/compose back into `mushpi-server/` — the cross-repo `COPY` would no longer reach `mushpi-client/`.
- **The build context is this repo's root.** A parent context (a directory holding the checkout) is sound *only because* `Dockerfile.dockerignore` exists beside the Dockerfile and BuildKit then filters the upload; a parent context with **no** ignore file is the old prohibition and still must be avoided: the whole orchestration tree — `.git`, ~1.4 GB of sibling `node_modules`, `.env`, sibling checkouts — is swept into the upload. The invariant is *every context needs its ignore file*, not "context = this repo's root".
- **`.dockerignore` has load-bearing entries — never "clean it up" by pattern.** `mushpi-server/` and `mushpi-client/` are the build inputs (`COPY`ed by the Dockerfile) and must **never** be listed there; `release.json` must stay un-ignored. `mushpi-grow` and `mushpi-mock` **stay** listed even though no `Dockerfile` `COPY`s them: `publish.yml` checks both out *into this root* on `v*` tag builds (tag-gated, for the `verify-release.sh` parity check) and the local verify recipe clones them, so the entry is a no-op on a branch push and real context-trimming on exactly those paths. `mushpi-docs` is deliberately **absent** — nothing materializes it here. Beyond the repos, the file also carries the usual VCS / dependency / secret / IDE exclusions; the operative rule is only that nothing a `COPY` reads may match. To check a change, extract every `COPY`/`ADD` source from the `Dockerfile` and confirm it is not matched — note `git check-ignore` reads `.gitignore`, **not** `.dockerignore`, so it is the wrong tool for this and gives misleading hits (the sibling clones are gitignored by design).
- **Provenance, so this is not re-litigated:** the sub-repo entries were authored on 2026-09-06 at the *orchestration root* (commit `c1de1d0`, beside `be-pico-hub` and `.opencode`, both since deleted) and imported verbatim by `5732f33` when the release machinery moved into this repo — hence their root-layout flavour. Grow and mock remain functional there; the `mushpi-docs` line was removed once the audit showed nothing ever materializes that clone.
- **A per-Dockerfile ignore file replaces the shared one — it does not merge.** BuildKit prefers `<dockerfile>.dockerignore` when it exists, and that file becomes the *entire* ignore set for that build. `Dockerfile.dockerignore` is therefore the authoritative list for the hub build, and anything the shared file excludes must be repeated there if that build needs it. **`mushpi-mock` must stay listed in the shared `.dockerignore`** — it is only a tag-gated parity-check checkout, not a build input, and removing it only bloats the context.
- Consequence for edits: a change to `.dockerignore` does **not** reach a build governed by `Dockerfile.dockerignore`. Check both when either moves.
- **Two ignore lists exist and only one is read per build: `.dockerignore` and `Dockerfile.dockerignore`.** `<dockerfile>.dockerignore` REPLACES the shared file, it does not merge** — so `Dockerfile.dockerignore` exists in practice for this context root, and the shared `.dockerignore` is read by no build any more. Keep them rule-for-rule mirrored (the file's own header says so); a divergence silently changes the CI/release build. Empirical rule for any change: extract every `COPY`/`ADD` source and confirm no pattern matches it in **both** files — `git check-ignore` reads `.gitignore` and is the wrong tool here.

## Yarn Berry 4 / Corepack

- The sub-repos are Yarn Berry 4, not Yarn 1. They pin Yarn via `"packageManager": "yarn@4.14.1"` in each `package.json` and rely on Corepack to run the pinned release. The official `node:*` images ship Yarn 1 **and** remove/disable Corepack, so the Dockerfile must `RUN corepack enable` in **every** stage.
- Never `npm install -g yarn@4`. The `yarn` npm package is Yarn 1; Yarn 2+ is Corepack-only. Without Corepack, `yarn workspaces focus` and `yarn install --immutable` fail.

## `better-sqlite3` native build

- Needs `python3 make g++` in the **runtime** stage only, installed before `yarn workspaces focus --all --production`. Its install script tries a prebuilt binary, then falls back to `node-gyp rebuild`, which needs Python and a C++ compiler.
- The `client-build`/`server-build` stages do **not** need the toolchain — they install full dev dependencies, where prebuilds suffice.

## Client API regeneration + the `tsc` gate

- `mushpi-client/src/api/generated/*` is gitignored, so the client-build stage regenerates it from the committed `mushpi-server/spec/openapi.json` (`yarn gen:client && yarn gen:schemas`). `openapi-generator-cli` needs a JRE (`default-jre-headless`).
- The client's `yarn build` (`tsc`) is a hard gate. If the server's committed spec is missing fields (entities lacking `@ApiProperty`), the regenerated types are incomplete and the build fails. That is a **server contract bug — flag it, don't hack around it**.

## Entrypoint & runtime details

- The server entrypoint is `dist/src/main.js`, not `dist/main.js` — tsc's `rootDir` is the project root because `docs/` and `spec/` are in the compile set. `CMD ["node", "dist/src/main.js"]`.
- `APP_SECRET` is optional (LAN/Tailscale is the auth boundary), which is why the HEALTHCHECK sends no Authorization header.
- `PICO_ANNOUNCE_SECRET` is required in production and belongs in `.env`.

### Entrypoint & data directory

- The runtime `ENTRYPOINT` is `scripts/docker-entrypoint.sh`. The image has **no `USER` directive** — it starts as root so the entrypoint can fix a host bind-mount the Docker daemon created as `root` (a fresh clone has no `./mushpi-data`, and the daemon creates a missing bind-mount source root-owned). It then drops privileges and `exec`s the CMD as `node` (UID/GID 1000, matching Raspberry Pi OS's default `pi` user).
- As root it `mkdir -p`s `/data`, `/data/images` and `/data/logs`, and for each one — only when the top-level owner is not already `node:node` — runs `chown -R node:node`. The `stat` guard keeps the recursive walk off the steady-state restart path.
- A failed `chown` (read-only mount, or a filesystem that maps root to an unprivileged user such as NFS `root_squash`) exits 1 telling the operator to pre-create the directory as UID/GID 1000 on the host.
- Ownership alone is not trusted: the entrypoint verifies `/data` is writable *as `node`* (`setpriv … test -w`) before dropping, so a permission surprise fails loudly instead of surfacing inside the app.
- **Do not "simplify" this back to an assert-only guard.** The earlier never-chown version made `docker compose up` fail on every fresh clone — the reported first-run bug.
- Unprivileged starts stay guarded: `docker run --user <non-root>` skips the root branch, and an unwritable/root-owned `/data` exits 1 with the host remedy `sudo chown -R <uid>:<gid> <MUSHPI_HUB_DATA_DIR>`.
- No-volume fallback: run the image with no `/data` mount and the baked tree (created and owned in the runtime stage) still passes — `docker run ghcr.io/mushroom-pi/mushpi-hub` boots fine for smoke tests; data just doesn't persist.
- An override command passed to `docker run` (e.g. `docker run … bash`) is still guarded: ownership is fixed, privileges dropped, then it is `exec`ed.
- **Consequence of the root start: `docker exec` now lands as root, not `node`.** PID 1 still runs as `node`; only the exec default changed. Pass `--user node` when it matters.

## `APP_HTTPS_ENABLED` (browser-facing HTTPS)

- Interpolated from `.env` and passed **into** the container as `APP_HTTPS_ENABLED: ${APP_HTTPS_ENABLED:-false}`. Unlike `MUSHPI_HUB_DATA_DIR`/`MUSHPI_HUB_IMAGE_TAG` it is a runtime env var, not interpolation-only. It declares the browser-facing deployment; it does **not** configure TLS.
- Keep it `false` (the default) for any plain-HTTP deployment — a LAN Pi is one. When `true`, the server sends `Strict-Transport-Security` and retains the CSP `upgrade-insecure-requests` directive; when `false` it sends neither.
- **On an HTTP deployment `true` breaks the UI.** `upgrade-insecure-requests` makes the browser rewrite the SPA's own asset URLs to `https://` with no HTTP fallback, so the page renders blank white with no API calls and the console reports `SSL_ERROR_RX_RECORD_TOO_LONG` (TLS spoken to a plaintext port). Browsers exempt `localhost` as a trustworthy origin, which is why it bites a LAN hostname/IP but not local dev.
- Set it `true` only when TLS is genuinely terminated in front (Tailscale Serve, a reverse proxy) or served directly.
- Server-side detail (the schema flag, the middleware, the HSTS/CSP gating) lives in `mushpi-server/REFERENCE.md`.

## Rate limiting (`MAX_REQUESTS` / `MAX_REQUESTS_TIME`)

- Throttling is **opt-in**: it registers only when **both** vars are set as positive integers — `MAX_REQUESTS` (requests per window) and `MAX_REQUESTS_TIME` (window length in **milliseconds**). Recommended starting values `MAX_REQUESTS=300` / `MAX_REQUESTS_TIME=60000` (≈5 req/s sustained per client IP), shipped commented out in `.env.example`. With the pair absent the server registers no throttler: no 429s and **no `X-RateLimit-*` headers at all**. Setting **only one** is a configuration error — the server fails at boot rather than half-configuring the guard.
- The pair is **deliberately not hard-coded** in `docker-compose.yml` or the `Dockerfile`: a hard default would silently override the server's opt-in design with no clean off switch, and would surface as unexplained 429s on the dashboard's read endpoints. Activation is operator-side only — compose passes `.env` through the service's `env_file`, so uncommenting the pair in `.env` is the entire mechanism.
- The tracker is **per client IP, per container instance**: in-memory, resets on restart/redeploy, not shared across replicas.
- The server does **not** enable Express `trust proxy`, so behind a reverse proxy every client appears to come from the proxy's IP and shares one bucket — size the limit accordingly, or leave the pair unset.
- Route scope: `/health` is always exempt (`@SkipThrottle()`), so the container HEALTHCHECK can never be rate limited; `/ping` and the `/v1/*` application routes are throttled only when the pair is configured.
- Server-side detail (the Joi pair validation, the throttler factory, the guard and header semantics) lives in `mushpi-server/REFERENCE.md`.

## `release.json` in the build context

- The client-build stage bakes `__APP_RELEASE_VERSION__` into the SPA from `release.json` (the sidebar footer). Keep **both** halves: `COPY release.json /app/release.json` in the Dockerfile **and** `release.json` absent from `.dockerignore`.
- Breaking either half fails **silently** — the image still builds, but the footer shows its `dev` fallback with no build error. The two halves are coupled.

## Tag & CI semantics

- **Neither publish workflow has ever actually executed.** No `v*` tag has been cut and `release.json` is still pre-1.0, so `publish.yml` has never run. `publish-dev.yml` **has** run — the registry carries its `dev-sha-*` and pre-release tags — but the release path remains **unverified until a real run**: a wrong action owner (`actions/setup-qemu-action` instead of `docker/setup-qemu-action`) sat undetected in `publish.yml` from the day it was written. Verify every `uses:` owner against the registry (`git ls-remote --tags https://github.com/<owner>/<repo> refs/tags/<tag>`) rather than trusting the file's own history, and remember `actionlint` cannot lint composite actions.

- The image is `ghcr.io/${{ github.repository_owner }}/mushpi-hub` — named after this repo, because this repo is the entry point that assembles server and client into the deployable hub. The owner stays interpolated so an org rename cannot break the name. This replaced the earlier product-name rule; renaming the repo and renaming the image are now the same decision, taken together.
- A `vX.Y.Z` tag pins only **this repo's** files (Dockerfile, compose, CI, `release.json`). Sub-repos build at their **default-branch HEAD**, not at any ref the tag records — so sub-repo release commits (including `mushpi-mock`) must be pushed **before** the tag.
- On tag builds CI checks out all four sub-repos and runs `scripts/verify-release.sh` (the parity check), which cross-checks the manifest against each sub-repo's committed version. Grow and mock are checked out solely so that check can run; they never enter the image.
- **`latest` is emitted by two independent mechanisms — changing one and not the other surprises you.** `publish.yml` passes metadata-action `flavor: latest=auto` (the action's default; it now travels through the shared composite action), which generates `latest` for tag-type rules — so a `v*` tag push moves `latest` on its own. The workflow's explicit `type=raw,value=latest` rule covers pushes to `main`, and its condition is bound **by ref** (`github.ref == 'refs/heads/main'`) rather than to the repository's default-branch setting — so which branch is the default cannot enable or disable it.

## Dev / pre-release image builds

- `publish-dev.yml` is `workflow_dispatch`-only. Inputs: `hub_ref` (default `main`), `server_ref`/`client_ref` (blank = that repo's default branch), a required free-form `image_tag`, and `push` (default true; false = build without pushing — multi-platform cannot `load`, so nothing is exported).
- Tag rules: `latest` and a strict `vX.Y.Z` (or `X.Y.Z`) are rejected so a dev run can never be mistaken for a release; pre-release forms (`0.9.0-rc1`) pass. Every build also gets `dev-sha-<short>` (metadata-action concatenates `prefix=dev-sha-` with the 7-char SHA verbatim). `flavor: latest=false` guarantees `latest` is never emitted.
- The release-manifest guard and `scripts/verify-release.sh` are deliberately skipped — a dev build is not a bundle release.
- Run a dev image on the Pi: set `MUSHPI_HUB_IMAGE_TAG=<tag>` in `.env`, then `docker compose pull && docker compose up -d`.
- Pre-release convention: an `0.9.0-rc1` image is a test candidate only; the actual release is cut by the `v0.9.0` git tag plus the `release.json` bump through `publish.yml`. Never retag an rc image as the release — rebuild on the tag.
- Cleanup of dev tags is **manual only** (no scheduled workflow, no retention policy): delete stale versions in the GHCR package UI or API.

## Shared build action (`.github/actions/build-image`)

- The composite action is **deliberately dumb**: toolchain setup, login, metadata, build/push only. **Callers own triggers, guards and tag policy** — each workflow passes its own `registry`/`image_name` (from its `env`), `token`, `push`, `flavor` and `tags`. That explicit local policy is what guarantees a dev build cannot move `latest`. **Never add a `mode: release|dev` input, or any ref/branch logic, to the action.**
- The optional `file` input (default `./Dockerfile`) selects which Dockerfile to build. **The hub callers must not pass it** — omitting it is what keeps the hub path byte-identical, and the default is the contract. It currently has no caller: its only consumer was the mock job, which now lives in the private `mushpi-demo` repo. Keep it as a build-input selector, not ref or tag logic, so it does not breach the "stays dumb" rule.
- `flavor` and `tags` are **required** inputs. `publish.yml` passes `latest=auto` (metadata-action's default; a `v*` tag push moves `latest`), `publish-dev.yml` passes `latest=false`.
- Composite actions cannot reliably read the `secrets` context — the token arrives as the `token` input (`token: ${{ secrets.GITHUB_TOKEN }}` from each caller; both keep `packages: write`). `push` is a string: the action compares `inputs.push == 'true'`.
- `.gitignore` allowlists `.github/actions/**` explicitly (mirroring `!.github/workflows/**`). A new file under `.github/actions/` that falls outside that pattern is silently uncommittable, which breaks both workflows in CI.
- actionlint lints the two workflows but **not** the action file — it parses explicit file arguments as workflows (rhysd/actionlint#401).

## Local verify/build prerequisites

- `scripts/verify-release.sh` and a local `docker build` need **bash, git, and jq** (the script parses JSON with `jq`), plus GNU `grep`/`sort`. Windows contributors run under **WSL**.
- Materialize the four siblings as transient clones **inside this repo** (they are gitignored — never vendored):
  ```bash
  for r in mushpi-server mushpi-client mushpi-grow mushpi-mock; do
    git clone https://github.com/mushroom-pi/$r.git
  done
  ```
  A local verify can instead clone from working trees. Plain self-hosting needs none of this.

## `docker-compose.override.yml` & local `.env`

- `docker-compose.override.yml` is untracked by design: it switches compose from pulling the published image to building locally. Self-hosters' clones never contain it.
- Copy `.env.example` → `.env` before a local `docker compose up`. `.env` is gitignored and never committed.
- **A local build can silently run a stale published image.** In build mode the image is tagged from the base file's `image:` field, so if `MUSHPI_HUB_IMAGE_TAG` names a tag already present locally (e.g. a pulled `0.9.0-alpha`), `docker compose up -d` skips the rebuild and starts the old image. Use a private tag for local verification (or force the rebuild) so you are testing the tree you built.

## Host networking (`network_mode: host`)

- The `mushpi-hub` service runs on the **host network**, and there is deliberately **no `ports:` block — that absence is load-bearing.** Compose treats `ports:` together with `network_mode: host` as incompatible (current Compose v2 warns and discards the mapping; some versions error), so never "restore" the published port as a cleanup.
- Why it is **required, not a preference**: the server reaches growing units at `http://<handle>.local:<port>`, and on Docker's default bridge that path is dead — the container cannot send or receive LAN multicast, so `.local` never resolves and only the announced-IP fallback carries the poll. Host networking is what puts the container on the LAN.
- Consequence: the server binds the hub's port 3000 **directly on the host**. A host service already listening on 3000 collides at boot (previously the clash surfaced as a port-publish error). The image `HEALTHCHECK` is unaffected — under host networking the container's `127.0.0.1` is the host's loopback.
- **No network isolation.** The container shares the host's entire network stack and can see every host interface and all of its traffic. Accepted for a single-purpose appliance; do not describe the trade-off as free.
- Host networking is **Linux-only**; Docker Desktop for mac/Windows does not provide it, so the build-mode override does not behave the same there. The override's `build:` block still merges cleanly with `network_mode: host` and runs in the host namespace.

## Container mDNS resolver (`.local` unit names)

- The image carries its **own mDNS resolver** so the server can reach growing units at `http://<handle>.local:<port>` without depending on anything the self-hoster's host provides. It is a **query-only** daemon: `[server] enable-dbus=no`, `use-ipv4=yes`, `use-ipv6=no`; `[publish] disable-publishing=yes`, `disable-user-service-publishing=yes`; `[reflector] enable-reflector=no`. **Never re-enable publishing**: the container shares the host's network namespace, so a second responder claiming names would collide with the host's own mDNS stack.
- The entrypoint starts it as root before the privilege drop; it daemonizes, and `dumb-init` is PID 1 so its exit is reaped. **A failed start is logged, never fatal** — the server still boots and the announced-IP fallback carries the poll. Nothing supervises the daemon: if it dies, `.local` resolution stops until the container restarts.
- The NSS wiring uses the **full `mdns4` plugin, not `mdns4_minimal`**, together with `/etc/mdns.allow` listing `.local.` and `.local`. The `_minimal` variants first send an SOA query for the `local` domain to the configured DNS server, which adds latency and misbehaves when that server does not answer `NXDOMAIN`; the allow-file makes `.local` authoritative for the plugin with no unicast-DNS pre-check. The `hosts:` line must be written unconditionally — do not rely on the package's post-install to have inserted a particular spelling, since a silent no-op there yields "resolver running, nothing resolves".
- The daemon runs **without its chroot step** (its default chroot is a container friction point and buys nothing here).
- Verify resolution **as the user the server runs as**, not only as root: `docker exec --user node <container> getent hosts <handle>.local`. A root-shell check can pass while the app still fails on the resolver socket's permissions.
- The alternative shape (not built) borrows the **host's** resolver instead: install only the NSS client and bind-mount the host's resolver socket. It is smaller but host-dependent — it silently degrades wherever the host does not run one. The divergence is confined to the Dockerfile packages, the entrypoint's start step and one compose volume.
