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

This section defines how Mushroom Pi versions its components, bundles them into a release, and reasons about compatibility — **what a version means and when it changes**. *How* a release is mechanically published is the Release Workflow section below.

There are **three orthogonal version axes** in this project, and conflating them is the single most common mistake. They are kept separate throughout this section:

1. **Per-component SemVer** — `MAJOR.MINOR.PATCH` for each of the three shipping components (firmware, server, client). Tracks each component's own evolution.
2. **Release-bundle counter** — the `release` field plus its git tag `vX.Y.Z`, a separate release-repo-level number recording the component combination tested together. It is not derived from, and not required to exceed, any component version.
3. **API-contract version (`api_version`)** — a plain integer, bumped *only* when the Pico↔Server REST contract breaks. It is not a SemVer and is not owned by any single component.

The axes are independent: a firmware **MAJOR** bump *usually* accompanies an `api_version` bump, but a **PATCH** firmware fix never changes `api_version`, and a contract-breaking change can land inside any-size component bump — all without moving the release counter, which moves on its own schedule. `api_version` is the field the Pico↔Server runtime compatibility handshake consumes.

### Version-axis reference

| Version axis | Field / artifact | Owner | Consumer |
|---|---|---|---|
| Per-component SemVer — firmware | `_SOFTWARE_VERSION` (`mushpi-grow/app/state.py`) | `mushpi-grow` | Server (runtime — see *api_version* below) |
| Per-component SemVer — server | `version` (`package.json`) | `mushpi-server` | Client (build-time — see *Client ↔ Server lockstep* below) + Pico units (runtime, as caller) |
| Per-component SemVer — client | `version` (`package.json`) | `mushpi-client` | Human operator (terminal UI — no API consumers) |
| Release bundle | `release.json` (5 required fields) + git tag `vX.Y.Z` | `mushpi-hub` | Operator, release audit |
| `api_version` | integer ≥ 1, sourced from grow contract spec (`spec/openapi.yaml`) | `mushpi-grow` | Server (runtime handshake — see *api_version* below) |
| Mock (dual) | own `pyproject.toml` version + represented `VERSION`/`_SOFTWARE_VERSION`/`_API_VERSION` | `mushpi-mock` | Dev/demo — mirrors grow (see *Mock dual-versioning* below) |

Keep them in sync: server `package.json` == its OpenAPI `info.version`; grow `_SOFTWARE_VERSION` == its spec `info.version`; mock's `VERSION` == grow's `_SOFTWARE_VERSION`.

### Per-component SemVer

All three components use `MAJOR.MINOR.PATCH`. The bump rules differ per component because their **consumer relationships differ** — a version bump means "this may require the consumer to react," and the nature of that reaction depends on who the consumer is.

**General pre-1.0 note:** while a component is at `0.x.y`, it is treated as *unstable API* — the strict "MAJOR means breaking" guarantee is relaxed. This does not change the bump *discipline* below; it only affects how conservatively consumers treat the numbers. The release bundle is the real compatibility signal regardless of `0.x` status.

#### Firmware

Firmware version lives at `_SOFTWARE_VERSION` in `mushpi-grow/app/state.py`. **Sole API consumer: the server, at runtime.** The server polls `GET /`, proxies `/setpoints`, `/outputs`, `/setup`, `/control`, and reads `/system` and `/sensors`. A firmware change "breaks" its consumer when the server would have to change to keep working.

| Bump | What it means for firmware |
|------|---------------------------|
| **MAJOR** | Breaking change to the Pico↔Server REST contract: endpoint removed/renamed, incompatible request/response shape, changed semantics an old server would misread. A MAJOR bump *typically* coincides with an `api_version` bump (see *api_version* below) — but they are distinct fields. |
| **MINOR** | Backwards-compatible addition: new endpoint, new field, new capability (e.g. a new metric or control mode). Existing server code keeps working. |
| **PATCH** | Bug fix or internal refactor. No observable API change. |

#### Server

Server version lives at `version` in `mushpi-server/package.json`. **Two consumers with different compatibility models.** The server *provides* the HTTP API the client consumes (enforced at build time — see *Client ↔ Server lockstep* below) and *consumes* the Pico's API (enforced at runtime — see *api_version* below). The server's version bump signals are defined against its **own public HTTP API** (the client↔server contract) as the primary signal.

| Bump | What it means for the server |
|------|------------------------------|
| **MAJOR** | Breaking change to the server's HTTP API (the client↔server contract): removed/renamed endpoint, incompatible DTO change. Because the client is regenerated and shipped in the same image (see *Client ↔ Server lockstep* below), this is absorbed at build time — a MAJOR is a *coordinated* server+client change, never a runtime break. |
| **MINOR** | Backwards-compatible addition: new endpoint, new field, new feature. Client may optionally regenerate to use it. |
| **PATCH** | Bug fix or internal change. No API change. |

#### Client

Client version lives at `version` in `mushpi-client/package.json`. **No API consumers.** The client is the terminal of the chain — nothing machine-to-machine consumes it. Its version carries *product* meaning rather than contract safety, and it may legitimately sit at `0.x` for a long time.

| Bump | What it means for the client |
|------|------------------------------|
| **MAJOR** | Rare, and only for product-level breakage: a full re-platform, dropping a supported environment, or an operator-facing redesign. Never triggered by an API change (those are absorbed at build time). |
| **MINOR** | New feature: new page, new component, new capability. |
| **PATCH** | Bug fix, styling, copy. |

### The release bundle and its manifest

The manifest is a **5-field object, all fields required**. The four SemVer fields are fixed by the locked scheme; `api_version` is the Pico↔Server contract generation (see *api_version* below) that the runtime compatibility handshake consumes, and recording it makes the release auditable against that contract.

| Field | Type | Required | Semantics |
|-------|------|----------|-----------|
| `release` | string (`MAJOR.MINOR.PATCH`) | ✅ required | The release-bundle version. Equals the git tag `vX.Y.Z` **without** the `v`. Monotonic and independent of every component version. |
| `server` | string (`MAJOR.MINOR.PATCH`) | ✅ required | The `mushpi-server` `package.json` version included in this bundle. |
| `client` | string (`MAJOR.MINOR.PATCH`) | ✅ required | The `mushpi-client` `package.json` version included in this bundle. |
| `firmware` | string (`MAJOR.MINOR.PATCH`) | ✅ required | The `mushpi-grow` `_SOFTWARE_VERSION` this bundle is tested against. |
| `api_version` | integer (≥ 1) | ✅ required | The Pico↔Server API-contract generation this bundle targets (see *api_version* below). |

**Rules:**

- The four SemVer fields must be **strings** and `api_version` must be an **integer ≥ 1** — no numeric coercion, no `v` prefix inside the JSON.
- The `release` field **must equal** the git tag version (tag `v0.3.0` ⇔ `release: "0.3.0"`).
- The `release` version is **not derived** from, and is **not required to exceed**, any component version. It is a separate release-repo-level counter.
- `firmware` records the firmware this bundle was *tested against* — it is not bundled into any container image (Pico units are flashed over USB), so the manifest is the only place the release ties firmware to the shipped server+client pair.
- The file **persists between releases** — it is rewritten per release commit — and is committed at the release commit.

> **`api_version` source of truth.** The canonical contract artifact is the hand-authored grow spec (`mushpi-grow/spec/openapi.yaml`), which the firmware implements and the mock mirrors — they must agree. `api_version` is sourced from that grow spec/firmware — **never** from the server's URI `API_VERSION` (`mushpi-server/src/common/utils/api-version.ts`), which is an unrelated contract (see *api_version* below). The two `1`s coincide today but are distinct numbers (integer vs string) that may diverge. The server stores this integer per unit (from announce/poll) **and judges it against the supported range**, flagging each unit `compatible`, `incompatible`, or `unknown` — see *Judging the stored value* below.

**Example** (illustrative values — these are **not** the current repo versions):

```json
{
  "release": "0.3.0",
  "server": "0.7.2",
  "client": "0.4.1",
  "firmware": "0.9.0",
  "api_version": 1
}
```

### Release-counter SemVer

The `release` field's bump meanings are the usual SemVer ones — **PATCH** for fixes, **MINOR** for additive changes, **MAJOR** for breaking changes — relaxed by the pre-1.0 note above while the line is still at `0.x`.

> **Hard rule — never move a component's version backward.** A version, once shipped, is monotonic.

### Pre-release identifiers (out of scope)

Pre-release suffixes are **deliberately out of scope**. `-alpha`/`-rc` identifiers would force the manifest schema, the CI guard regex, and image tagging to accept suffixes — for no real gain with a single tester. Prototype status is conveyed in prose (a descriptive label), not in the version string. The strict `MAJOR.MINOR.PATCH` rule therefore stands: no `-alpha`, `-beta`, `-rc`, or build metadata in any component or release version.

### api_version — the Pico↔Server contract generation

`api_version` is the compatibility token for the **Pico↔Server** relationship. It is a separate integer, deliberately distinct from every component SemVer.

| Aspect | Definition |
|--------|-----------|
| **Type** | integer (not SemVer) |
| **Bumped when** | **Only** on a *breaking* change to the Pico↔Server REST contract — removed/renamed endpoint, incompatible request/response shape, changed semantics that an old-firmware unit would silently misbehave under. |
| **Not bumped on** | Additive/backwards-compatible changes (new endpoint, new field), bug fixes, or any change confined to the server's HTTP API or the client. |
| **Who consumes it** | The server: it reads the unit's value from announce/poll, **stores** it per unit, and **judges** it against the supported range — each unit is flagged `compatible`, `incompatible`, or `unknown` (see *Judging the stored value* below). |
| **Where it lives (semantics)** | Carried by the Pico in its announce payload and `GET /` response, stored per-unit by the server. The **field names and storage** are implementation detail — this section defines the *semantic* of the integer only. Source of truth: the hand-authored grow contract spec (`mushpi-grow/spec/openapi.yaml`), which the firmware implements and the mock mirrors; never the server's URI `API_VERSION` (see *The release bundle and its manifest* above). |

#### Orthogonality to SemVer

The two version systems are independent axes. This table illustrates valid combinations:

| Firmware `_SOFTWARE_VERSION` bump | `api_version` change? | Why |
|-----------------------------------|-----------------------|-----|
| PATCH (bug fix) | ❌ none | No contract change. |
| MINOR (new endpoint) | ❌ none | Additive — old server still works. |
| MAJOR (contract break) | ✅ bump to `2` | The break is precisely what `api_version` records. |
| MAJOR (firmware internal rewrite, no contract change) | ❌ none | SemVer MAJOR, but the wire contract is unchanged. |

The inverse holds too: `api_version` only moves when the **contract** moves, never merely because a component version moved. When `api_version` is bumped, the firmware's `_SOFTWARE_VERSION` **must also** receive at least a MINOR (in practice a MAJOR) — the contract cannot change while the firmware claims to be the same version — but the two are still separate fields.

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
- **Bump side effect:** on an `api_version` bump, the server's supported maximum must be updated **in the same pass** — it must track the grow spec's current contract generation (see *The release bundle and its manifest* above), or every unit would read as `incompatible` after the bump.

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

### Mock dual-versioning

`mushpi-mock` mirrors the Pico firmware's REST API for development, demos, and testing. Its canonical references are `mushpi-grow/spec/openapi.yaml` (contract) and `mushpi-grow/app/state.py::_SOFTWARE_VERSION` (version). Because it is a mirror **and** an independent service, it carries **three** version identities:

| Identity | Field(s) | Meaning | Bump discipline |
|----------|----------|---------|-----------------|
| **Represented firmware version** | `src/mushpi_mock/VERSION` + `state.py::_SOFTWARE_VERSION` | The firmware version the mock *emulates*. Must always equal the grow firmware. | Mirrors grow — bumped whenever `_SOFTWARE_VERSION` in grow bumps (orchestrator triggers the mock agent). |
| **Represented API contract version** | `state.py::_API_VERSION` | The Pico↔Server contract generation the mock *emulates*. Must always equal grow's `_API_VERSION`. | Mirrors grow — bumped in the same pass on a breaking contract change. |
| **Own service version** | `pyproject.toml` `version` | The mock tool's own evolution (features, fixes). | Independent SemVer, unrelated to grow. |

The mock-only `GET /version` endpoint returns all three at once (`mock_version`, `represented_firmware_version`, `represented_api_version`), so a demo can prove exactly which firmware the mock is emulating without confusing it with the tool's own release line.

#### Versioning considerations when the contract changes

- The mock **mirrors** `firmware_version` and `api_version` in both the announce payload and `GET /`, matching the grow spec's `AnnouncePayload` schema exactly (11 keys, order-matched). The mock reads the grow spec as canonical and is not permitted to drift.
- The mock reports its represented grow versions (`firmware_version` + `api_version`) on the mirrored endpoints, and its own mock version separately via the mock-only `GET /version` endpoint (`mock_version` + `represented_firmware_version` + `represented_api_version`).
- **When `api_version` bumps** (a breaking Pico contract change), the mock must be updated in the same pass as grow — an out-of-date mock would report the stale `api_version` and silently mask a real incompatibility during dev/demo.
- The alignment check (`scripts/check-version-alignment.sh`, see `mushpi-mock/AGENTS.md`) runs **two** checks: firmware (grow `_SOFTWARE_VERSION` vs both `src/mushpi_mock/VERSION` and `state.py::_SOFTWARE_VERSION`) and API (grow `_API_VERSION` vs `state.py::_API_VERSION`) — so grow⇔mock `api_version` drift is caught too.

## Release Workflow — Cutting a vX.Y.Z Bundle

*How* a release is cut, tagged, and shipped. What a release version *means* and the manifest schema are normative in **Version & Release Semantics** above — this section documents mechanics only and never restates the semantics.

### 0. Branch & release model

`main` is shipped; `dev` is where you work. The release is now multi-repo: each component's version bump lands as a release commit in that component repo's `main` (`mushpi-server`, `mushpi-client`, `mushpi-grow`, and `mushpi-mock` for the parity record), while the manifest commit — `release.json` in this repo — plus the `vX.Y.Z` tag land on **this repo's** `main`. Component versions bump only on those release commits, never on `dev`.

### 1. What a release is

A release is a **git tag `vX.Y.Z`** on this repo (`mushpi-hub`) plus a **committed `release.json` manifest at this repo's root**, kept in lockstep. The statement it makes — "these specific component versions are tested to work together" — and the 5-field manifest schema are normative in **Version & Release Semantics** above; tag ⇔ manifest equality is enforced twice (subsection 4's consistency rule, via the local pre-tag check and the CI manifest guard below).

> **CI status note:** `publish.yml` lives in this repo and triggers on pushes to `main` and on `v*` tags. A push to `main` publishes an image but does **not** create a GitHub Release, git tag or `release.json` change — those happen only on a `v*` tag push. The first published image comes from this repo's first `v*` tag cut after the release-repo split lands; before that there are no published image tags to watch.

### 2. When to cut a release

Cut a release when either of these holds:

- a feature that changed the **server** and/or **client** has landed with green verification — client regenerated if the OpenAPI contract changed; or
- a **firmware** release has been tested against the current server+client pair.

Never cut with dirty trees, red verification, an un-regenerated client after a contract change, or mid-feature.

### 3. Choosing the release version

The `release` field is an **independent monotonic counter** — never derived from, and never required to exceed, any component version. Per **Version & Release Semantics** above, the components snap to the project release line at milestone cuts and drift between cuts (the current bundle: release `0.8.0` with firmware `0.8.4`). Milestone progression: `0.8.0` baseline → `0.8.x` development cuts as the remaining MVP work lands → `0.9.0` = the complete MVP set shipped to the friend (prose: the "1.0 field prototype") → `0.9.x` fixes from feedback → `0.10.x` / `0.11.x` … larger pre-1.0 changes → `1.0.0` stability graduation.

### 4. The consistency rule

The git tag and the manifest state the same version:

```
git tag  vX.Y.Z   ⇔   release.json  "release": "X.Y.Z"     (no `v` inside the JSON)
```

Enforced by the local pre-tag check (subsection 9) — and, once publishing is live, by the CI manifest guard step in `publish.yml` (subsection 8), which fails the run before anything reaches GHCR if the tagged tree's manifest doesn't match the tag.

### 5. How the bundle maps onto the publish pipeline

*Cross-reference only — the pipeline itself is defined in `publish.yml`; don't duplicate it here.* The inline toolchain-setup/login/metadata/build-push steps are not in the workflow: they live in the shared composite action `.github/actions/build-image/action.yml`, which both publish workflows call. Each caller keeps its own triggers, guards and tag policy (`publish-dev.yml` passes `flavor: latest=false` there); the release-path flavor policy is the Image tags bullet below.

- On a `v*` tag push, `publish.yml` builds from **this repo@tag** (the tag pins the Dockerfile, compose, CI workflow, and `release.json`) plus `mushpi-server` and `mushpi-client` checked out at their **default-branch HEAD** — the tag pins no sub-repo code (`REFERENCE.md` → Tag & CI semantics). On tag builds the workflow also checks out `mushpi-grow` and `mushpi-mock` and runs the bundle-parity check.
- Image tags: `type=ref,event=tag` keeps the `v` (image tag `v0.8.0`), and `type=sha` adds a `sha-<short>` tag. `latest` comes from **two independent mechanisms**, so both must be visible in the workflow rather than one of them being implicit — hence `publish.yml` passes the metadata-action `flavor` as `latest=auto` **explicitly** (behaviour unchanged; it was the action's default before). The explicit flavor generates `latest` for tag-type rules, so a `v*` tag push moves `latest` on its own, with no explicit rule needed; and the workflow's explicit `type=raw,value=latest,enable=${{ github.ref == 'refs/heads/main' }}` rule covers pushes to `main` — bound to the `main` branch **by ref**, deliberately not to the repository's default-branch setting, so changing which branch is the default can neither enable nor disable `latest` on `main` pushes. Net effect: tag pushes carry `latest` via the explicit flavor, and `main` branch pushes carry it via the explicit rule.
- **The release version is the image-version axis.** The server's own version rides *inside* the image (`package.json` + the OpenAPI `info.version`) — it is not the image tag.
- **Firmware never enters the image** — Pico units are flashed over USB; the manifest is the only place a release records the firmware it was tested against.

### 6. Procedure

All paths are relative to this repo's root unless a directory is given.

1. **Decide the bump types** per component using the **Per-component SemVer** rules above — and whether the Pico↔Server contract broke (see *api_version* above), which determines `api_version`.
2. **Bump the three component version fields:** firmware `_SOFTWARE_VERSION` (`mushpi-grow/app/state.py`), server `package.json` `version`, client `package.json` `version`.
3. **Regenerate the client** if the server's OpenAPI contract changed: `yarn gen:all:remote` in `mushpi-client/` (build-time lockstep — see **Client ↔ Server lockstep** above).
4. **Sync the mock** if the firmware bumped: `src/mushpi_mock/VERSION` and the mock's `state.py::_SOFTWARE_VERSION` to the new firmware version (see **Mock dual-versioning** above).
5. **Verify the bundle:** in `mushpi-server/` `yarn build && yarn lint && yarn test && yarn test:e2e`; in `mushpi-client/` `yarn build && yarn lint`; optionally a mock integration run (the mock stands in for hardware — see subsection 7).
6. **Write `release.json`** in this repo (schema: **The release bundle and its manifest** above), reading every value **live from its source of truth** — never from memory:
   - server: `jq -r .version mushpi-server/package.json`
   - client: `jq -r .version mushpi-client/package.json`
   - firmware: `grep -oP '_SOFTWARE_VERSION\s*=\s*"\K[^"]+' mushpi-grow/app/state.py`

   `release` is the version chosen in step 1. `api_version` is currently the literal `1`; when it becomes versioned it is sourced from the grow firmware/spec — **never** from the server's URI `API_VERSION`.
7. **Materialize the four sub-repos** as transient clones inside this repo — `mushpi-server`, `mushpi-client`, `mushpi-grow`, `mushpi-mock` (they are gitignored; recipe in `REFERENCE.md`).
8. **Run the local pre-tag check** (subsection 9) — it must print `OK — release X.Y.Z is consistent`.
9. **Commit + push each remoted sub-repo** — `mushpi-server`, `mushpi-client`, `mushpi-grow`, and `mushpi-mock` (version bumps, spec, regenerated client). The mock is now checked out by CI for the parity check, so its release commit must be pushed too. Only `mushpi-docs` remains local-only: commit if you like, nothing to push.
10. **Commit this repo** — `release.json` plus any changes here — as *the release commit*, and tag it `vX.Y.Z` on that commit.
11. **Push this repo, then push the tag — the tag goes last.** Rationale: CI builds from the sub-repos' default-branch HEAD, not from refs the tag pins (`REFERENCE.md` → Tag & CI semantics) — the sub-repo release commits must already be on their remotes when the tag triggers the workflow, or the CI guard (subsection 8) fails the run on a manifest-vs-code mismatch.
12. **Watch the `publish.yml` run** on the tag (once publishing is live — subsection 1's status note).
13. **Log the release** in the post-release session log: bundle version, component versions, what shipped.

### 7. Mock & bundle tests

Whenever bundle tests run, the mock's **represented** firmware version (`src/mushpi_mock/VERSION`) must equal the manifest's `firmware` entry — otherwise the mock lies about what it emulates and the test proves nothing about the bundle. The mock is **not** a manifest field and never ships (see **Mock dual-versioning** above). The mock's existing alignment check (grow `_SOFTWARE_VERSION` vs `src/mushpi_mock/VERSION`, see `mushpi-mock/AGENTS.md`) remains the guard; the pre-tag check below bakes that comparison into the release flow itself.

### 8. The CI guards

`publish.yml` carries two steps, both placed after the sub-repo checkouts and before any build tooling, that fire only on `v*` tag pushes (`if: startsWith(github.ref, 'refs/tags/v')`):

The **manifest guard** enforces:

- **tag ⇔ manifest** — the pushed tag `vX.Y.Z` must equal the tagged commit's `release.json` `release` field (and the manifest must exist at that commit);
- **manifest shape** — the four SemVer strings plus an integer `api_version ≥ 1` (see **The release bundle and its manifest** above);
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
