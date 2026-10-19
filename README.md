# All of Create server (Docker, Debian)

Self-hosted dedicated server for the **All of Create** modpack (CurseForge project
[885460](https://www.curseforge.com/minecraft/modpacks/aoc), by quickqwek): Minecraft 1.21.1
on NeoForge, built on Debian 13 (trixie) slim with OpenJDK 21. It follows the
[modready.gg guide](https://modready.gg/guides/all-of-create-server).

## Quickstart

```bash
cd /home/debian/all-of-create-server
cp .env.example .env
$EDITOR .env                 # read https://aka.ms/MinecraftEULA and set EULA=TRUE if you accept it; set MEMORY
mkdir -p data                # must exist and be owned by uid 1000 before first start
docker compose pull          # prebuilt image from ghcr.io/ddsna/all-of-create-server
                             # (or build it yourself: docker compose build)
docker compose up -d
docker compose logs -f       # wait for: Done (..s)! For help, type "help"
```

Connect to `<host>:25565`. The first boot takes about 2-3 minutes. The healthcheck
(a TCP probe on 25565 with a 10-minute start period) reports `healthy` once the server listens.

Console:

* `docker exec all-of-create mc-cmd say hello`: send one command
* `docker attach all-of-create`: interactive console. Detach with Ctrl-p Ctrl-q, **not** Ctrl-c.
* RCON: set `RCON_PASSWORD` in `.env`. Port 25575 is not published by default.

Stop with `docker compose stop` (or `down`). tini passes SIGTERM to the entrypoint,
which types `stop` into the server console. You then see `Saving worlds` …
`All dimensions are saved` in the logs, and the process exits with code 0. `stop_grace_period` is 2m.

## Prebuilt image

`.github/workflows/image.yml` builds every push to `main` and publishes it to
GitHub Container Registry with three tags: the pack version, `latest` and
`sha-<commit>`:

```bash
docker pull ghcr.io/ddsna/all-of-create-server:2.6
```

Pull requests are built but not pushed. Set `IMAGE=` in `.env` to pin a
different tag, or a local build such as `IMAGE=all-of-create-server:dev`.

## What lives where

| Path | Owner | On upgrade |
|---|---|---|
| `/opt/aoc/server/libraries` (image) | image | replaced by the new image. `/data/libraries` is a symlink to it |
| `/data/mods` | image | replaced when the pack version changes. The old folder moves to `/data/backups/mods-<old>-<ts>` |
| `/data/config`, `/data/datapacks` | you | only files that **do not exist yet** are added. Your edits are kept |
| `/data/defaultconfigs` | image | always refreshed (templates for new worlds) |
| `/data/server.properties` | you | seeded once. Env overrides are applied on every start |
| `/data/world`, `ops.json`, `whitelist.json`, `logs/` | you | never touched (`ops.json`/`whitelist.json` are rewritten only if `OPS`/`WHITELIST` are set) |

The server writes `eula.txt` on every start, and only when `EULA=TRUE`.

## Configuration (.env)

`MEMORY` sets `-Xms`/`-Xmx` (default 8G). The JVM flags are the guide's G1 set
(`UseG1GC, ParallelRefProcEnabled, MaxGCPauseMillis=200, DisableExplicitGC,
G1NewSizePercent=30, G1MaxNewSizePercent=40, G1HeapRegionSize=8M`) plus the other
Aikar G1 tunings that still apply on JDK 21. `JVM_OPTS` appends more flags.
`ALWAYS_PRE_TOUCH=true` adds `-XX:+AlwaysPreTouch`.

Optional `server.properties` overrides: `MOTD`, `DIFFICULTY`, `MAX_PLAYERS`, `VIEW_DISTANCE`,
`SIMULATION_DISTANCE`, `ONLINE_MODE`, `LEVEL_SEED`, `ENABLE_WHITELIST`. `OPS` and `WHITELIST`
take comma-separated names. UUIDs come from the Mojang API, or are computed as offline UUIDs when `online-mode=false`.

The guide recommends `view-distance=10`, `simulation-distance=6` and `max-players=15`. For busy
servers it also suggests lowering `maxBlocksMoved` from 2048 to 1024 in `data/config/create-common.toml`,
pre-generating 3000-5000 blocks with Chunky, and profiling with `/spark profiler`.

## Resource sizing

| Players | MEMORY (guide) | MEM_LIMIT (container) |
|---|---|---|
| 1-4 | 6G | 8g |
| 5-10 | 8G (default) | 10g |
| 10-15 | 10G | 12g |
| 15+ | 12G+ | MEMORY + 2g |

Keep `MEM_LIMIT` about 1.5-2 GB above `MEMORY`, because metaspace and native memory for
~200 mods sit outside the heap. The guide prefers fewer fast cores (4 cores, 4.5 GHz+) over many slow ones.
Disk: the image is ~820 MB, and a fresh `/data` is ~330 MB before the world grows.

Smoke test on a 3.8 GB VM: the pack booted fully with `MEMORY=2G` (container RSS ~2.2 GB),
but that is far too little for real play.

## Upgrading when the pack version changes

1. On CurseForge (Files tab), find the new "All of Create 1.21.1 - vX.Y" file and its
   **server pack** file. The file id, download URL and SHA-1 are on the file page, or come from
   `https://api.curseforge.com/v1/mods/885460/files/<serverPackFileId>` (needs an API key; the public
   proxy `https://api.curse.tools/v1/mods/885460/files/<id>` works without one).
2. Open the new server pack's `variables.txt` and read `MODLOADER_VERSION`. Get the matching
   installer SHA-256 from
   `https://maven.neoforged.net/releases/net/neoforged/neoforge/<ver>/neoforge-<ver>-installer.jar.sha256`.
3. Update the ARGs in `Dockerfile` (`PACK_VERSION`, `SERVER_PACK_URL`, `SERVER_PACK_SHA1`,
   `NEOFORGE_VERSION`, `NEOFORGE_INSTALLER_SHA256`) and the `image:` tag in `compose.yaml`.
   The build fails if the pack's `variables.txt` disagrees with `NEOFORGE_VERSION`.
4. **Back up `data/`** (see below), then run `docker compose build && docker compose up -d`.
   The mods are swapped and the old mods go to `data/backups/`. New config files are added.
   Changed default values inside config files you already have are **not** applied. To take the
   pack's configs wholesale, start once with `RESEED_CONFIG=true`, which moves the old `config/` to
   `data/backups/config-<ts>`. Then set it back to false.

Mods you add by hand to `data/mods` are moved aside on every pack-version change. Re-add them afterwards.

## Backups

The whole server state is `data/`. For a consistent copy, stop the server first:

```bash
docker compose stop
tar -C /home/debian/all-of-create-server -czf aoc-backup-$(date +%F).tgz data --exclude data/backups
docker compose start
```

For a live backup, run `docker exec all-of-create mc-cmd save-off` and then `mc-cmd save-all flush`.
Copy `data/world`, then run `mc-cmd save-on`. You can delete `data/backups/` once an upgrade is confirmed good.

## Version pins (sourced 2026-10-19)

| Pin | Value | Source |
|---|---|---|
| Pack | All of Create 1.21.1 - **v2.6** (client file 9164652, released 2026-10-13) | CurseForge files API for project 885460 (via api.curse.tools). The modready.gg guide mentions v1.8 (May 2026), which is now outdated |
| Server pack | `All_of_Create_v2.6_serverpack.zip`, file **9164660**, SHA-1 `2ad6376911a23b28dd17fceaa31b4cbe4df7bd7b` | CurseForge file metadata (`hashes`, algo 1 = SHA-1). Verified on download |
| Minecraft | 1.21.1 | Guide (recommended version) and the pack's `variables.txt` |
| NeoForge | **21.1.256** | The server pack's `variables.txt` (`MODLOADER_VERSION`). The guide names no loader version |
| NeoForge installer SHA-256 | `4aad931e…348c` | maven.neoforged.net `.sha256` file |
| Java | 21 (Debian `openjdk-21-jre-headless`, 21.0.12.1 at build time) | Guide ("Java 21" for 1.21.1 NeoForge) and `variables.txt` `RECOMMENDED_JAVA_VERSION=21` |
| Base image | `debian:trixie-slim` (Debian 13.7 at build time) | Request. Pass `--build-arg DEBIAN_IMAGE=debian:trixie-slim@sha256:…` to pin a digest |
| Heap default | 8G | Guide: 8 GB baseline for 5-10 players |
| JVM flags | see above | Guide, plus Aikar's flags |

Notes: the guide's start command uses `-jar neoforge-server.jar`. Modern NeoForge installers produce no
such jar. The image launches with `@libraries/net/neoforged/neoforge/<ver>/unix_args.txt` instead, as
the installer's own `run.sh` does. The pack's bundled `start.sh` (ServerStarterJar plus a Java download)
is not used. The loader is installed at build time.
