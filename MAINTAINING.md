# Mushroom Pi — Maintaining It (Packaging & Release)

This is the maintainer-facing half: packaging internals and the release process. Operators should read the deployment guide on the published documentation site instead: [`github.com/mushroom-pi/mushpi-docs`](https://github.com/mushroom-pi/mushpi-docs). This document describes what happens; the agent-facing rules for editing the machinery here live in `REFERENCE.md`.

## How the image is built

The image is built by `Dockerfile` from this repository's root as its Docker context. CI checks out the two build inputs — `mushpi-server` and `mushpi-client` — into that root and builds there; on a `v*` tag it also checks out `mushpi-grow` and `mushpi-mock` so the bundle-parity check can run. Firmware never enters the image; the manifest records what the bundle was tested against. The result is pushed to `ghcr.io/mushroom-pi/mushpi-hub` — the image is **named after this repo**, because this repo is what assembles `mushpi-server` and `mushpi-client` into the deployable hub, so the image name and the repo name say the same thing on purpose; the owner stays interpolated from `github.repository_owner`, so an org rename cannot break the name. Locally, the siblings are materialized as transient clones inside this repo; the recipe and the packaging guardrails are in `REFERENCE.md`.

## Container Networking Notes (mDNS / `.local`)

How the server reaches Pico units from inside the container. This is factual behavior of the current setup, not a locked decision.

The compose service runs with `network_mode: host` — the container shares the hub's network stack and sits directly on the LAN rather than behind Docker's NAT bridge. That is what lets the image carry its own name resolver and reach units by name.

- **The image resolves `.local` names itself.** The image bakes in a small, **query-only** mDNS resolver (`avahi-daemon` plus the `libnss-mdns` NSS client), so the server resolves `http://{handle}.local:{port}` without depending on anything the host provides. Two properties matter operationally:
  - **It never *publishes* names.** Publishing is disabled in the baked-in config on purpose: because the container shares the host's network namespace, a second responder claiming `.local` names would collide with the host's own mDNS stack. The resolver answers lookups only, so it cannot conflict with the hub's resolver.
  - **A failure to start is not fatal.** The server boots regardless and logs a warning, then falls back to the address each unit last announced. The worst a failed resolver costs is `.local` resolution — never a boot.
- **Host networking gives up isolation — and it is Linux-only.** The container is reachable on the host's interfaces exactly as the host is, with no network isolation. This is an accepted trade for a single-purpose appliance, not a free lunch. It also means host networking (and therefore this resolver) is Linux-only.
- **The announced-address fallback is the safety net, not the primary path.** A unit is normally reached by its `.local` name; the server falls back to the address the unit last announced only when the name does not resolve (or the resolver failed to start). Because a unit's IP can drift on a DHCP lease change, the name — not the IP — is the stable identity.

**Verifying resolution.** Inside the running container, run `getent hosts <unit>.local` **as the user the server runs as** — `docker exec --user node <container> getent hosts <unit>.local` — not as root, because a check run as root can mask a permission problem the `node` user would hit. Do **not** use `avahi-browse` or `avahi-resolve`: the resolver's D-Bus interface is deliberately switched off, so those tools fail even when `.local` resolution works.

## Version & Release Semantics (Normative)

> **Status:** Normative — defines what a version means and when it changes. The operational mechanics that enact it are the **Release Workflow** section below, which documents mechanics only and never restates the semantics.

This section defines how Mushroom Pi versions its software and reasons about compatibility — **what a version means and when it changes**. *How* a release is mechanically published is the Release Workflow section below.

Mushroom Pi versions its components independently: every shipping component — grow (firmware), server, client, mock and the hub bundle itself — carries its **own SemVer** (`MAJOR.MINOR.PATCH`), bumped when that component changes. A release is one number, recorded once in `mushpi-hub/release.json` and tagged `vX.Y.Z` on the hub repo, and it **names the versions it ships** rather than imposing a shared number: it moves with the release, and a component that did not change keeps its previous version. There is no single suite SemVer that every component's version field must equal — that older framing is retired.

Exactly **one other version axis** exists alongside the component versions: `api_version`, an integer **Pico↔Server contract generation**. It is **not** a release number — it moves only on a *breaking* change to the Pico↔Server REST contract, never merely because a release is cut, and a release never bumps it.

### Component versions

| Component | Field(s) | Where it lives |
|---|---|---|
| Firmware (grow) | `_SOFTWARE_VERSION` | `mushpi-grow/app/state.py` |
| Server | `version` | `mushpi-server/package.json` |
| Client | `version` | `mushpi-client/package.json` |
| Mock | `version` + `VERSION` + `_SOFTWARE_VERSION` (three fields, one value) | `mushpi-mock/pyproject.toml`, `src/mushpi_mock/VERSION`, `src/mushpi_mock/state.py` |
| Hub bundle | `release` field + git tag `vX.Y.Z` | `mushpi-hub/release.json` |

**Single source of truth** for the mock's version is the firmware: `mushpi-grow/app/state.py::_SOFTWARE_VERSION`. Grow lands first in a release, and the mock mirrors that value — `scripts/verify-release.sh` asserts the firmware⇔mock agreement. The server and client carry their own versions, each bumped when that component changes; they do not mirror the firmware's.

The **mock carries one version identity equal to the firmware's** — no separately-tracked tool SemVer. Its own `pyproject.toml` `version`, `src/mushpi_mock/VERSION` and `state.py::_SOFTWARE_VERSION` all move together to grow's `_SOFTWARE_VERSION`, and move only when the firmware moves, because the mock impersonates firmware and its release version must equal what it represents. `mushpi-mock/scripts/check-version-alignment.sh` enforces the grow↔mock agreement (a firmware three-way check plus an API two-way check); the older "independent mock own-service SemVer" notion is retired.

**Strict SemVer.** Every component version — and the release tag — is strict `MAJOR.MINOR.PATCH` — no `-rc`, `-alpha`, or `+build` metadata in any component version or tag. Pre-release suffixes are deliberately out of scope: `-alpha`/`-rc` identifiers would force the manifest schema, the CI guard regex and image tagging to accept suffixes, for no real gain with a single tester. Prototype status is conveyed in prose (a descriptive label), not in the version string. This strict rule is enforced at runtime in one place: the `firmware_version` a unit reports on announce must be strict SemVer, or the server rejects the announce with **422** — which also breaks the server's IP-refresh fallback.

**Bump meanings.** The usual SemVer semantics apply — **MAJOR** for breaking changes, **MINOR** for backwards-compatible additions, **PATCH** for fixes and internal changes — relaxed by the pre-1.0 note while the line is at `0.x` (a `0.x.y` version is treated as *unstable API*: the strict "MAJOR means breaking" guarantee is relaxed, but the bump discipline above stands).

> **Hard rule — never move the version backward.** A version, once shipped, is monotonic.

### The release manifest

`release.json` records the release number alongside the version of each of the four shipping artifacts plus the contract generation, so a release is auditable as a tested-together set. It is a **5-field object, all fields required**.

| Field | Type | Required | Semantics |
|-------|------|----------|-----------|
| `release` | string (`MAJOR.MINOR.PATCH`) | ✅ required | The release number. Equals the git tag `vX.Y.Z` **without** the `v`. |
| `server` | string (`MAJOR.MINOR.PATCH`) | ✅ required | The `mushpi-server` `package.json` version this release ships. |
| `client` | string (`MAJOR.MINOR.PATCH`) | ✅ required | The `mushpi-client` `package.json` version this release ships. |
| `firmware` | string (`MAJOR.MINOR.PATCH`) | ✅ required | The `mushpi-grow` `_SOFTWARE_VERSION` this bundle ships. |
| `api_version` | integer (≥ 1) | ✅ required | The Pico↔Server API-contract generation this bundle targets (see *api_version* below). |

**Rules:**

- The four SemVer fields must be **strings** and `api_version` must be an **integer ≥ 1** — no numeric coercion, no `v` prefix inside the JSON. A component untouched by the release keeps its previous version, so the fields need not all be equal.
- The `release` field **must equal** the git tag version (tag `v0.9.0` ⇔ `release: "0.9.0"`), and the component fields must equal the versions those components ship in the release.
- `firmware` records the firmware this bundle ships — it is not bundled into any container image (Pico units are flashed over USB), so the manifest is the only place the release ties firmware to the shipped server+client pair.
- The file **persists between releases** — it is rewritten per release commit — and is committed at the release commit.

> **`api_version` source of truth.** The canonical contract artifact is the hand-authored grow spec (`mushpi-grow/spec/openapi.yaml`), which the firmware implements and the mock mirrors — they must agree. `api_version` is sourced from that grow spec/firmware — **never** from the server's URI `API_VERSION` (`mushpi-server/src/common/utils/api-version.ts`), which is an unrelated contract (see *api_version* below). The two `1`s coincide today but are distinct numbers (integer vs string) that may diverge. The server stores this integer per unit (from announce/poll) **and judges it against the supported range**, flagging each unit `compatible`, `incompatible`, or `unknown` — see *Judging the stored value* below.

**Example** — a release that moved the release number and the server only; the unchanged firmware and client keep their previous versions:

```json
{
  "release": "0.10.0",
  "server": "0.10.0",
  "client": "0.9.0",
  "firmware": "0.9.0",
  "api_version": 1
}
```

### api_version — the Pico↔Server contract generation

`api_version` is the compatibility token for the **Pico↔Server** relationship. It is a separate integer, deliberately distinct from every component's SemVer.

| Aspect | Definition |
|--------|-----------|
| **Type** | integer (not SemVer) |
| **Bumped when** | **Only** on a *breaking* change to the Pico↔Server REST contract — removed/renamed endpoint, incompatible request/response shape, changed semantics that an old-firmware unit would silently misbehave under. |
| **Not bumped on** | Additive/backwards-compatible changes (new endpoint, new field), bug fixes, or any change confined to the server's HTTP API or the client. |
| **Who consumes it** | The server: it reads the unit's value from announce/poll, **stores** it per unit, and **judges** it against the supported range — each unit is flagged `compatible`, `incompatible`, or `unknown` (see *Judging the stored value* below). |
| **Where it lives (semantics)** | Carried by the Pico in its announce payload and `GET /` response, stored per-unit by the server. The **field names and storage** are implementation detail — this section defines the *semantic* of the integer only. Source of truth: the hand-authored grow contract spec (`mushpi-grow/spec/openapi.yaml`), which the firmware implements and the mock mirrors; never the server's URI `API_VERSION` (see *The release manifest* above). |

#### Orthogonality to component versions

The component versions and `api_version` are independent axes. This table illustrates valid combinations:

| Component version bump | `api_version` change? | Why |
|--------------------|-----------------------|-----|
| PATCH (bug fix) | ❌ none | No contract change. |
| MINOR (new endpoint) | ❌ none | Additive — old server still works. |
| MAJOR (contract break) | ✅ bump to `2` | The break is precisely what `api_version` records. |
| MAJOR (internal rewrite, no contract change) | ❌ none | SemVer MAJOR, but the wire contract is unchanged. |

The inverse holds too: `api_version` only moves when the **contract** moves, never merely because a release was cut. When `api_version` is bumped, the firmware's version — and the server's, which shares the contract — **must also** receive at least a MINOR (in practice a MAJOR) — the contract cannot change while the firmware claims to be the same version — but the two are still separate fields.

#### Relationship to the server's `/v1/` URI prefix

Two *different* contracts are often confused, and both currently carry the number `1`:

| Version | Governs | Bumped on |
|---------|---------|-----------|
| Server URI prefix `/v1/` (`API_VERSION`) | The **server↔client** HTTP API (NestJS URI versioning) | Breaking change to the server's public HTTP API |
| `api_version` | The **Pico↔Server** contract | Breaking change to the Pico REST API |

They start at the same value by design, but may **diverge** in the future: a server↔client breaking change (URI → `v2`) may occur with no Pico contract change, and a Pico contract break (`api_version` → `2`) may occur with no change to the server's URI prefix. Do not treat them as one number.

#### Judging the stored value (supported range & bump side effect)

The server judges each unit's stored `api_version` against its supported range and exposes the verdict as one of three states — **`compatible`**, **`incompatible`**, or **`unknown`**:

- **`compatible`** — the stored value is within the supported range.
- **`incompatible`** — a non-null stored value outside the range. This also covers a unit that has **never reported a version but has been contacted** (its firmware predates the handshake — it needs a firmware update).
- **`unknown`** — the unit has **never reported a version and never been contacted** — the server has no basis to judge.

Two normative properties of this check:

- **The supported ceiling is verdict-only, never a validation bound.** Out-of-range values are accepted and stored so they can be flagged (**accept-and-flag**) — never rejected, so a unit running a newer contract generation is never lost from the server.
- **Bump side effect:** on an `api_version` bump, the server's supported maximum must be updated **in the same pass** — it must track the grow spec's current contract generation (see *The release manifest* above), or every unit would read as `incompatible` after the bump.

The verdict is computed, not stored, and is separate from the unit's health `status` — a unit can be healthy and `incompatible` at once. As everywhere in this scheme, the verdict's field name is implementation detail; this section defines the three outcomes only.

### Client ↔ Server lockstep (build-time compatibility)

The client and server are a **build-time lockstep**, not a runtime handshake. This is a locked architectural decision:

1. The client SPA is regenerated from the server's OpenAPI spec (`yarn gen:all:remote` in `mushpi-client/`) — the server's code is the source of truth.
2. The built SPA is shipped **inside the same container image** as the server (single-container deployment; one image, one port).
3. Therefore a client↔server mismatch is **impossible to ship**: you cannot build a container whose SPA was generated against a different server than the one inside it.

**Consequence:** no runtime version handshake exists between client and server. The release bundle records the lockstep as a `server`+`client` pair, and making the running release visible in the UI is how the operator confirms what's deployed — but that visibility is informational, not a compatibility gate.

#### Two compatibility models, contrasted

| | Client ↔ Server | Pico ↔ Server |
|---|---|---|
| **Enforced at** | Build time | Runtime |
| **Mechanism** | OpenAPI regen + same container image | Announce/poll carrying `firmware_version` + `api_version` |
| **Can a mismatch ship?** | No — physically impossible in the single image | Yes — Pico units are flashed independently over USB |
| **Can a unit update itself?** | n/a (server redeploy pulls new image) | No — no OTA; the server must *learn* the unit's version |
| **Handshake needed?** | No | Yes — the server stores each unit's `api_version` and judges it against the supported range: `compatible`, `incompatible`, or `unknown` (see *Judging the stored value* above) |
| **Failure mode** | n/a | A unit reporting an out-of-range `api_version` is flagged `incompatible` ("needs firmware update"); a contacted unit that never reported one is also `incompatible` (firmware predates the handshake); a unit never reported and never contacted stays `unknown` |

The asymmetry is the entire reason `api_version` exists *only* for the Pico↔Server side: the client↔server side never needs a runtime guard because the build system makes drift impossible.

### The mock and `GET /version`

`mushpi-mock` mirrors the Pico firmware's REST API for development, demos, and testing — and because it impersonates firmware, it carries **one version identity equal to the firmware's** (see *Component versions* above): its own `pyproject.toml` `version`, `src/mushpi_mock/VERSION` and `state.py::_SOFTWARE_VERSION` all equal grow's `_SOFTWARE_VERSION` and move together. There is no separately-tracked mock tool SemVer.

The mock-only `GET /version` endpoint returns three fields — `mock_version`, `represented_firmware_version`, `represented_api_version` — because they answer different questions. `mock_version` and `represented_firmware_version` now always carry the same value; the fields stay separate so a demo can distinguish "which tool is this" from "which firmware does it emulate".

- The mock **mirrors** `firmware_version` and `api_version` in both the announce payload and `GET /`, matching the grow spec's `AnnouncePayload` schema exactly (11 keys, order-matched). The mock reads the grow spec as canonical and is not permitted to drift.
- **When `api_version` bumps** (a breaking Pico contract change), the mock's `state.py::_API_VERSION` must be updated in the same pass as grow — an out-of-date mock would report the stale `api_version` and silently mask a real incompatibility during dev/demo.
- The alignment check (`scripts/check-version-alignment.sh`, see `mushpi-mock/AGENTS.md`) runs **two** checks: firmware (grow `_SOFTWARE_VERSION` vs both `src/mushpi_mock/VERSION` and `state.py::_SOFTWARE_VERSION`) and API (grow `_API_VERSION` vs `state.py::_API_VERSION`) — so grow⇔mock `api_version` drift is caught too, and the script enforces the grow↔mock agreement that the mock's version identity relies on.

### The mock image is published separately

The mock image `ghcr.io/mushroom-pi/mushpi-mock` is published by **`mushpi-mock`'s own** `publish.yml`, on a `v*` tag pushed to that repo (or a manual dispatch naming an existing tag) — not by this repo, and not by `mushpi-demo`. The two image tags are **independent and generally differ**: `MUSHPI_HUB_IMAGE_TAG` tracks a hub release (server + dashboard), while `MUSHPI_MOCK_IMAGE_TAG` tracks the **last mock release** — the mock's own tag, which carries the firmware's version and moves only when the firmware's version does — and a release that does not move the firmware's version leaves the mock tag alone. The workflow refuses a tag that does not equal `mushpi-mock/src/mushpi_mock/VERSION`; the published demo consumes the mock image **anonymously**, so the package must be made public on GHCR once, by hand (CI publishes it private).

## Release Workflow — Cutting a vX.Y.Z Bundle

*How* a release is cut, tagged, and shipped. What a release version *means* and the manifest schema are normative in **Version & Release Semantics** above — this section documents mechanics only and never restates the semantics.

### 0. Branch & release model

`main` is the trunk in every repo; `dev` is a rolling integration branch. Work accumulates on `dev`, and each repo's release commit is the **final commit of the cycle on `dev`** — so the reviewed `dev`→`main` PR *is* the shipped tree. Never bump on `main` after the merge: that hides the shipped tree from review and forces the realign to be a force-push. `git log main..dev` is the canonical unreleased set in every repo — never reconstruct a changelog by hand.

**Hotfixes.** Never branch a fix off a tag. Fix forward on `dev`, then release again through the normal cycle. This is the recorded stance while nothing is in production.

### 1. What a release is

A release is a **git tag `vX.Y.Z`** on this repo (`mushpi-hub`) plus a **committed `release.json` manifest at this repo's root**, kept in lockstep. The statement it makes — "these specific component versions are tested to work together" — and the 5-field manifest schema are normative in **Version & Release Semantics** above; tag ⇔ manifest equality is enforced twice (subsection 4's consistency rule, via the local pre-tag check and the CI manifest guard below).

> **CI status note:** `publish.yml` lives in this repo and triggers on **`v*` tag pushes only**. A merge to `main` publishes nothing — no image, no GitHub Release, no git tag, no `release.json` change. The image builds and publishes only when the `v*` tag is pushed, after the manifest guard and parity check pass.

### 2. When to cut a release

Cut a release when either of these holds:

- a feature that changed the **server** and/or **client** has landed with green verification — client regenerated if the OpenAPI contract changed; or
- a **firmware** release has been tested against the current server+client pair.

Never cut with dirty trees, red verification, an un-regenerated client after a contract change, or mid-feature.

### 3. Choosing the release version

Each component's version is its **own SemVer** (see **Version & Release Semantics** → *Component versions*), bumped by its meaning when that component changes — **MAJOR** for breaking changes, **MINOR** for backwards-compatible additions, **PATCH** for fixes — and left alone when the component did not change. The release names the versions it ships: unchanged components keep their previous versions in the manifest. `api_version` moves only if the Pico↔Server contract broke; a routine release leaves it untouched.

### 4. The consistency rule

The git tag and the manifest state the same version:

```
git tag  vX.Y.Z   ⇔   release.json  "release": "X.Y.Z"     (no `v` inside the JSON)
```

Enforced by the local pre-tag check (subsection 9) — and, once publishing is live, by the CI manifest guard step in `publish.yml` (subsection 8), which fails the run before anything reaches GHCR if the tagged tree's manifest doesn't match the tag.

### 5. How the bundle maps onto the publish pipeline

*Cross-reference only — the pipeline itself is defined in `publish.yml`; don't duplicate it here.* The inline toolchain-setup/login/metadata/build-push steps are not in the workflow: they live in the shared composite action `.github/actions/build-image/action.yml`, which both publish workflows call. Each caller keeps its own triggers, guards and tag policy (`publish-dev.yml` passes `flavor: latest=false` there); the release-path flavor policy is the Image tags bullet below.

- On a `v*` tag push, `publish.yml` builds from **this repo@tag** (the tag pins the Dockerfile, compose, CI workflow, and `release.json`) plus `mushpi-server` and `mushpi-client` checked out at their **default-branch HEAD** — the tag pins no sub-repo code (`REFERENCE.md` → Tag & CI semantics). On tag builds the workflow also checks out `mushpi-grow` and `mushpi-mock` and runs the bundle-parity check.
- Image tags: `type=ref,event=tag` keeps the `v` (image tag `v0.9.0`), and `type=sha` adds a `sha-<short>` tag. **`latest` moves on the `v*` tag alone**: the metadata-action's explicit `flavor: latest=auto` generates `latest` for the tag-type rule, so a tag push advances `latest` with no separate rule. (An older `type=raw,value=latest` rule bound to `main` may still sit in the workflow as inert leftover config, but it is not what moves `latest` — a merge to `main` publishes nothing, per subsection 1's status note.)
- **The release version is the image-version axis.** The server's own version rides *inside* the image (`package.json` + the OpenAPI `info.version`) — it is not the image tag.
- **Firmware never enters the image** — Pico units are flashed over USB; the manifest is the only place a release records the firmware it ships (the firmware's own version, which moves only when the firmware does).

### 6. Procedure

All paths are relative to this repo's root unless a directory is given.

1. **Choose the component versions** — only for the components that changed, each by its own meaning — per **Version & Release Semantics** above, and decide whether the Pico↔Server contract broke (see *api_version*), which determines `api_version`. Components that did not change keep their previous versions.
2. **Cut each repo's release commit on `dev`** as the final commit of that repo's cycle:
   - **grow** — bump `_SOFTWARE_VERSION` if the firmware changed (grow lands first in the merge order, subsection 3); if the contract broke, also bump `_API_VERSION` and update the spec `info.version`.
   - **mock** — mirror grow: bump `pyproject.toml` `version`, `src/mushpi_mock/VERSION` and `state.py::_SOFTWARE_VERSION` (and `_API_VERSION` if it moved), then `uv lock`.
   - **server** — bump `package.json` `version`, then regenerate `spec/` via `yarn spec:all`.
   - **client** — bump `package.json` `version`; regenerate the client if the server's OpenAPI contract changed (`yarn gen:all:remote` in `mushpi-client/` — build-time lockstep, see **Client ↔ Server lockstep** above).
   The version bump is the **final commit on `dev`**, never on `main` after the merge.
3. **Order the merges: grow and mock before the server, the server before the hub tag.** An old firmware announcing `software_version` is rejected 422 by a new server (the `forbidNonWhitelisted` pipe drops the renamed field), and that 422 breaks the server's IP-refresh fallback — so the firmware must land first. The hub tag comes last, after the server's PR is merged, because the tag-triggered build checks out each sub-repo at its default-branch HEAD.
4. **Open one `dev`→`main` PR per repo**, carrying a plain-language new/changed/fixed summary with **operator actions at the top** (re-flash, reconfigure, re-pair, migration). Opening a PR publishes nothing.
5. **Merge each PR with a merge commit — never squash or rebase** — so `dev` stays an ancestor of `main` and `git log main..dev` keeps working as the unreleased query.
6. **Verify the bundle:** in `mushpi-server/` `yarn build && yarn lint && yarn test && yarn test:e2e`; in `mushpi-client/` `yarn build && yarn lint`; optionally a mock integration run (the mock stands in for hardware — see subsection 7).
7. **Write `release.json`** in this repo as the hub's release commit on `dev` (schema: **The release manifest** above), reading every value **live from its source of truth** — never from memory (a component that did not change keeps its previous version, so the four SemVer fields need not all be equal):
   - server: `jq -r .version mushpi-server/package.json`
   - client: `jq -r .version mushpi-client/package.json`
   - firmware: `grep -oP '_SOFTWARE_VERSION\s*=\s*"\K[^"]+' mushpi-grow/app/state.py`

   `api_version` is sourced from the grow firmware/spec — **never** from the server's URI `API_VERSION`.
8. **Materialize the four sub-repos** as transient clones inside this repo — `mushpi-server`, `mushpi-client`, `mushpi-grow`, `mushpi-mock` (they are gitignored; recipe in `REFERENCE.md`).
9. **Run the local pre-tag check** (subsection 9) — it must print `OK — release X.Y.Z is consistent`.
10. **Tag `vX.Y.Z` on this repo's merge commit and push it — the tag goes last.** Rationale: CI builds from the sub-repos' default-branch HEAD, not from refs the tag pins (`REFERENCE.md` → Tag & CI semantics) — the sub-repo release commits must already be on their remotes when the tag triggers the workflow, or the CI guard (subsection 8) fails the run on a manifest-vs-code mismatch.
11. **Fast-forward `dev` to `main`** (`git merge --ff-only main`) so the branches never diverge across the cycle boundary.
12. **Watch the `publish.yml` run on the tag** — it builds and publishes the image, and only now (from the tag).
13. **Log the release** in the post-release session log: the release number, the component versions that changed, and what shipped.

### 7. Mock & bundle tests

Whenever bundle tests run, the mock's **represented** firmware version (`src/mushpi_mock/VERSION`) must equal the manifest's `firmware` entry — otherwise the mock lies about what it emulates and the test proves nothing about the bundle. The mock is **not** a manifest field and never ships (see **The mock and `GET /version`** above). The mock's existing alignment check (grow `_SOFTWARE_VERSION` vs `src/mushpi_mock/VERSION`, see `mushpi-mock/AGENTS.md`) remains the guard; the pre-tag check below bakes that comparison into the release flow itself.

### 8. The CI guards

`publish.yml` carries two steps, both placed after the sub-repo checkouts and before any build tooling, that fire only on `v*` tag pushes (`if: startsWith(github.ref, 'refs/tags/v')`):

The **manifest guard** enforces:

- **tag ⇔ manifest** — the pushed tag `vX.Y.Z` must equal the tagged commit's `release.json` `release` field (and the manifest must exist at that commit);
- **manifest shape** — the four SemVer strings plus an integer `api_version ≥ 1` (see **The release manifest** above);
- **manifest ⇔ code being built** — the manifest's `server`/`client` must equal the checked-out sub-repos' `package.json` versions; this is what catches a tag cut before the sub-repo release commits were pushed.

The **bundle-parity step** then runs `scripts/verify-release.sh "${GITHUB_REF_NAME}"`, cross-checking the manifest against every committed component version — server/client `package.json`, firmware `_SOFTWARE_VERSION` and the grow spec's `info.version`, and the mock's `VERSION`. This is why the grow and mock checkouts exist.

**What stays local:** the monotonicity check — that no version moved backward relative to `main:release.json`. CI checks out a single ref, so `main` is not available there and the script skips that comparison; the pre-tag check (subsection 9) covers it.

### 9. Pre-tag check

At this repo's root, with the four siblings materialized, just before tagging:

```bash
./scripts/verify-release.sh vX.Y.Z
```

It must print `OK — release X.Y.Z is consistent`. It checks the manifest shape, the tag⇔`release` equality, that no version moved backward, that `release.json` matches the committed component versions (server/client `package.json`, firmware `_SOFTWARE_VERSION`, mock `VERSION`), and that each component's spec `info.version` matches. Requires `jq`.

**Rollback** is just pinning the compose `image:` tag to the older `vX.Y.Z` image tag and `docker compose up -d`.

## Dev & Pre-Release Image Builds (`publish-dev.yml`)

A manual-only complement to the release workflow above: Actions → *publish-dev* → Run workflow. It builds the same image and publishes it to GHCR without touching the release path.

**Inputs:**

- `hub_ref` — the `mushpi-hub` ref to build (default `main`).
- `server_ref` / `client_ref` — optional pins for the two sub-repos to specific refs; blank uses their default branches.
- `image_tag` — required, free-form.
- `push` — toggle; off builds without publishing.

**Tag rules:** `latest` and a strict release-shaped `vX.Y.Z` are rejected, so a dev run can never be confused with a release or move `latest`. Pre-release-shaped tags such as `0.9.0-rc1` are accepted. Each build additionally gets a `dev-sha-<short>` tag for traceability. `latest` is still owned solely by the normal release workflow.

Dev builds deliberately skip the release-manifest guard and `scripts/verify-release.sh` — they are not bundle releases.

**Pre-release convention.** To test a candidate before a release, dispatch with `image_tag: 0.9.0-rc1`, and pull it on the target host via `MUSHPI_HUB_IMAGE_TAG`. The real release is still cut the normal way — the `vX.Y.Z` tag plus the matching `release.json` change in one commit, through `publish.yml`. Never retag an rc image as the release; rebuild it on the tag.

**Cleanup (manual).** Dev tags are not deleted automatically and there is no retention policy. Delete stale versions by hand from the GHCR package page for `ghcr.io/mushroom-pi/mushpi-hub` (or via the GitHub API) when they pile up.
