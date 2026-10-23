# 🍄 Mushroom Pi 🍓 — Ops (Release & Packaging)

![Docker](https://img.shields.io/badge/docker-%230db7ed.svg?style=for-the-badge&logo=docker&logoColor=white)![GitHub](https://img.shields.io/badge/github-%23121011.svg?style=for-the-badge&logo=github&logoColor=white)![GitHub Actions](https://img.shields.io/badge/github%20actions-%232671E5.svg?style=for-the-badge&logo=githubactions&logoColor=white)![Git](https://img.shields.io/badge/git-%23F05033.svg?style=for-the-badge&logo=git&logoColor=white)

This repository publishes the container image for the Mushroom Pi system. The hub image serves the NestJS API and the built React dashboard on port 3000. The hub runs on any Docker-capable single-board computer (64-bit OS required); the tested reference board — a Raspberry Pi 3 Model B v1.2 (1 GB of RAM) — is the bare minimum, not a requirement. The container runs with host networking (Linux Docker only) and binds port 3000 directly on the hub, so that port must be free.

The image is published to **`ghcr.io/mushroom-pi/mushpi`** (the hub). This repo also owns the compose service definition — `docker-compose.yml` — and the release manifest that pins which component versions ship together.

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

A demo environment — the full system running against simulated Pico units, with nothing to flash — exists separately from this repository. It lives in the private `mushroom-pi/mushpi-demo-infra` repo (not publicly linkable), is not part of this release, and self-hosters do not need it.

## What's here

| File | Purpose |
|---|---|
| `docker-compose.yml` | Compose service that pulls the published image |
| `Dockerfile` | Builds the single-container image from this repo's root as context |
| `.env.example` | Environment template (`PICO_ANNOUNCE_SECRET` plus optional overrides) |
| `release.json` | Release manifest — the component versions in this bundle |
| `scripts/verify-release.sh` | Checks the manifest against the committed component versions |
| `.github/workflows/publish.yml` | CI: builds and pushes the hub image on `main` and `v*` tags |
| `DEPLOYMENT.md` | Release-repo notes for operators — the full deployment guide is on the documentation site |
| `MAINTAINING.md` | How to build and release it (maintainers) |

Application code lives in the sibling repositories `mushpi-server`, `mushpi-client`, `mushpi-grow`, and `mushpi-mock` — this repo holds the packaging layer only.
