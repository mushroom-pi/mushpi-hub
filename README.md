# 🍄 Mushroom Pi 🍓 — Ops (Release & Packaging)

![Docker](https://img.shields.io/badge/docker-%230db7ed.svg?style=for-the-badge&logo=docker&logoColor=white)![GitHub](https://img.shields.io/badge/github-%23121011.svg?style=for-the-badge&logo=github&logoColor=white)![GitHub Actions](https://img.shields.io/badge/github%20actions-%232671E5.svg?style=for-the-badge&logo=githubactions&logoColor=white)![Git](https://img.shields.io/badge/git-%23F05033.svg?style=for-the-badge&logo=git&logoColor=white)

This repository publishes the container images for the Mushroom Pi system. The hub image serves the NestJS API and the built React dashboard on port 3000. The hub runs on any Docker-capable single-board computer (64-bit OS required); the tested reference board — a Raspberry Pi 3 Model B v1.2 (1 GB of RAM) — is the bare minimum, not a requirement. The container runs with host networking (Linux Docker only) and binds port 3000 directly on the hub, so that port must be free.

The images are published to **`ghcr.io/mushroom-pi/mushpi`** (the hub) and **`ghcr.io/mushroom-pi/mushpi-mock`** (the mock — the simulated Pico units the demo stack runs). This repo also owns the compose service definitions — `docker-compose.yml` for the hub, `docker-compose.demo.yml` for the demo stack — and the release manifest that pin which component versions ship together.

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

Open `http://localhost:3000` (or `MUSHPI_DEMO_PORT`) — no login. The five units — `mock-tent-1` … `mock-tent-5` — announce themselves to the server on startup and behave like real units, and 15 days of backdated readings are pre-seeded on startup so the charts have data immediately (`DEMO_SEED_DAYS=0` skips seeding; another number changes the depth).

`bash scripts/demo-stack.sh -d` runs detached; on that path the script also verifies the seeded history actually landed before it reports success, exiting non-zero with guidance if it did not. The announce secret can come from `.env` (the laptop path above) or from the environment — exporting `PICO_ANNOUNCE_SECRET` works equally well, so a hosted deployment can inject it platform-side; a `.env` file is not required. The demo runs from its own compose file, `docker-compose.demo.yml`, keeps its throwaway state in `./mushpi-demo-data` (override with `MUSHPI_DEMO_DATA_DIR`), and never touches a real installation's `./mushpi-data`. One prerequisite: it needs a `mushpi` image built with the demo profile.

## What's here

| File | Purpose |
|---|---|
| `docker-compose.yml` | Compose service that pulls the published image |
| `docker-compose.demo.yml` | Demo stack compose — the hub plus five simulated units, with its own isolated state |
| `Dockerfile` | Builds the single-container image from this repo's root as context |
| `Dockerfile.mock` | Builds the mock image |
| `.env.example` | Environment template (`PICO_ANNOUNCE_SECRET` plus optional overrides) |
| `release.json` | Release manifest — the component versions in this bundle |
| `scripts/verify-release.sh` | Checks the manifest against the committed component versions |
| `scripts/demo-stack.sh` | The demo stack's single entry point |
| `.github/workflows/publish.yml` | CI: builds and pushes both images on `main` and `v*` tags |
| `DEPLOYMENT.md` | Release-repo notes for operators — the full deployment guide is on the documentation site |
| `MAINTAINING.md` | How to build and release it (maintainers) |

Application code lives in the sibling repositories `mushpi-server`, `mushpi-client`, `mushpi-grow`, and `mushpi-mock` — this repo holds the packaging layer only.
