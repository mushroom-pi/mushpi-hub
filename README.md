# 🍄 Mushroom Pi 🍓 — Ops (Release & Packaging)

![Docker](https://img.shields.io/badge/docker-%230db7ed.svg?style=for-the-badge&logo=docker&logoColor=white)![GitHub](https://img.shields.io/badge/github-%23121011.svg?style=for-the-badge&logo=github&logoColor=white)![GitHub Actions](https://img.shields.io/badge/github%20actions-%232671E5.svg?style=for-the-badge&logo=githubactions&logoColor=white)![Git](https://img.shields.io/badge/git-%23F05033.svg?style=for-the-badge&logo=git&logoColor=white)

This repository publishes the container images for the Mushroom Pi system. The hub image serves the NestJS API and the built React dashboard on port 3000. The hub runs on any Docker-capable single-board computer (64-bit OS required); the tested reference board — a Raspberry Pi 3 Model B v1.2 (1 GB of RAM) — is the bare minimum, not a requirement. The container runs with host networking (Linux Docker only) and binds port 3000 directly on the hub, so that port must be free.

The images are published to **`ghcr.io/mushroom-pi/mushpi`** (the hub) and **`ghcr.io/mushroom-pi/mushpi-mock`** (the mock — the simulated Pico units the demo stack runs). This repo also owns the compose service definitions — `docker-compose.yml` for the hub, and for the demo stack a `docker-compose.demo.base.yml` plus two overlays (published and local-build) — and the release manifest that pins which component versions ship together.

## Run it

The self-hosting path — no build step, no agent tooling:

```bash
git clone https://github.com/mushroom-pi/mushpi-ops.git mushpi-ops
cd mushpi-ops
cp .env.example .env       # set PICO_ANNOUNCE_SECRET
docker compose up -d
```

Open port 3000 on the hub — it must be free, since the container binds it directly on the host network (Linux Docker only). This pulls the published image — you never build locally. The compose file reads optional variables from `.env`: `MUSHPI_DATA_DIR` (the host directory holding the database, images and logs; defaults to `./mushpi-data`) and `MUSHPI_IMAGE_TAG` (the image tag to pull; defaults to `latest`). `.env` also carries a few optional server runtime options — for example, uncommenting the `MAX_REQUESTS` / `MAX_REQUESTS_TIME` pair from `.env.example` opts the server into request throttling. Full deployment instructions — SD-card provisioning (Raspberry Pi Imager ≥ 2.0.6), first boot, Pico unit registration, the update workflow, backups, and remote access — live on the published documentation site: **[`github.com/mushroom-pi/mushpi-docs`](https://github.com/mushroom-pi/mushpi-docs)** (the `deployment/` pages; remote access under `configuration/`). `DEPLOYMENT.md` in this repo keeps only the release-repo notes: the image and the `.env` variables that shape the run, with their gotchas.

The local build toggle `docker-compose.override.yml` is deliberately untracked, so it never appears in a clone: a plain `docker compose up -d` always pulls the published image. Maintainers who want to build from source keep a local copy of that override.

## Try it without hardware

The demo stack is the hardware-free alternative: one command brings up the whole system locally — the hub (server + dashboard) plus five simulated Pico units — so you can see a populated dashboard with no hardware and nothing to flash. It is additive and isolated — a real hub deployment is unchanged and keeps using `docker compose up` above.

```bash
git clone https://github.com/mushroom-pi/mushpi-ops.git mushpi-ops
cd mushpi-ops
cp .env.example .env        # set PICO_ANNOUNCE_SECRET: openssl rand -hex 32
bash scripts/demo-stack.sh
```

Open `http://localhost:3000` (or `MUSHPI_DEMO_PORT`) — no login. The five units — `tent-one` … `tent-five` — announce themselves to the server on startup and behave like real units (the roster's sixth, `tent-six`, is seeded offline and deliberately has no mock), and the server seeds 15 days of backdated readings on boot so the charts have data immediately (`SEED_READINGS_DAYS` sets the depth; `0` is a boot validation error — disable seeding with `SEED_ENABLED=false`).

`bash scripts/demo-stack.sh -d` runs detached; on that path the script runs two verification steps before it reports success, exiting non-zero with guidance if either fails. The first checks the seeded history actually landed: each of the five live units (`tent-one` … `tent-five`) must hold exactly 15 days × 1440 readings (21 600), counted inside a window anchored to that unit's own oldest reading rather than the wall clock — so a healthy seed is not misread when the verifier runs a minute later than the seed boundary. A short or absent seed means boot seeding did not complete, and the failure points at the `Demo seeding start — boundary …` and `Demo seeding complete` lines in `docker compose -f docker-compose.demo.base.yml -f docker-compose.demo.yml logs mushpi`. The second confirms the five mocked units are actually being polled — each has a recorded IP and at least one reading from the last couple of poll intervals (it waits up to ~150 s for the first live poll). A failure there is a separate class, `POLL IDENTITY VERIFICATION FAILED`, and points at `Pico unit N unreachable (… tent-X.local …)` in the same log — the server falling back to mDNS because the announced IP/port was not persisted. It never blames seeding. The announce secret can come from `.env` (the laptop path above) or from the environment — exporting `PICO_ANNOUNCE_SECRET` works equally well, so a hosted deployment can inject it platform-side; a `.env` file is not required. The demo runs from its own compose files — the shared base `docker-compose.demo.base.yml` plus the overlay that selects where its images come from — keeps its throwaway state in `./mushpi-demo-data` (override with `MUSHPI_DEMO_DATA_DIR`), and never touches a real installation's `./mushpi-data`. One prerequisite: the demo profile is compiled into the server, not switched on at runtime, so the image must come from a build whose code carries it — and no published tag does yet, which is exactly why the local route below exists.

The same demo can also be **built and run locally** — no CI run, no registry, nothing pulled from GHCR. `scripts/demo-stack-local.sh` builds both images on this machine from your own working copies and runs the identical stack. It needs the three sibling repos — `mushpi-server`, `mushpi-client`, `mushpi-mock` — checked out **beside** this one (the build context is the directory holding `mushpi-ops`; a clone of each is enough, and uncommitted changes are included by design):

```bash
bash scripts/demo-stack-local.sh
```

The trade-off is honest: it needs those three repos on disk **and** a Docker build of both images, where the published route above needs neither. And the demo port still defaults to `3000`, which collides with anything already listening there — the hub's own port, another checkout's demo — so set `MUSHPI_DEMO_PORT` to move the host side (the container side stays `3000`). Same stack, same read-only dashboard, same throwaway `./mushpi-demo-data` state; the full procedures live on the documentation site.

Running it locally does **not** make it a development environment. Both routes use the same `NODE_ENV=demo` profile, and that profile refuses every write with `403` except Pico announce — you cannot create batches, edit recipes or manage units from the dashboard. Building from your working copies changes where the code came from, not what the stack allows; it is there so you can confirm your changes still produce the showcase. For a stack you can actually write to, run the server in its normal dev/local profile instead.

## What's here

| File | Purpose |
|---|---|
| `docker-compose.yml` | Compose service that pulls the published image |
| `docker-compose.demo.base.yml` | Demo stack service definitions — the profile, network, mounts and verification shared by both demo modes; never run alone |
| `docker-compose.demo.yml` | Demo published-image overlay — merges onto the base, pulling the two GHCR images (the default mode) |
| `docker-compose.demo-local.yml` | Demo local-build overlay — merges onto the base, building both images from the sibling working copies |
| `Dockerfile` | Builds the single-container image from this repo's root as context |
| `Dockerfile.mock` | Builds the mock image |
| `.env.example` | Environment template (`PICO_ANNOUNCE_SECRET` plus optional overrides) |
| `release.json` | Release manifest — the component versions in this bundle |
| `scripts/verify-release.sh` | Checks the manifest against the committed component versions |
| `scripts/demo-stack.sh` | The demo stack's single entry point (published mode) |
| `scripts/demo-stack-local.sh` | The demo stack's local-build entry point — no CI, no registry |
| `.github/workflows/publish.yml` | CI: builds and pushes both images on `main` and `v*` tags |
| `DEPLOYMENT.md` | Release-repo notes for operators — the full deployment guide is on the documentation site |
| `MAINTAINING.md` | How to build and release it (maintainers) |

Application code lives in the sibling repositories `mushpi-server`, `mushpi-client`, `mushpi-grow`, and `mushpi-mock` — this repo holds the packaging layer only.
