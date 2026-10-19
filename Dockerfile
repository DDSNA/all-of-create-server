# syntax=docker/dockerfile:1
#
# All of Create (CurseForge project 885460) dedicated server, NeoForge 1.21.1.
# Every version pin lives in the ARGs below; see README.md "Version pins".

ARG DEBIAN_IMAGE=debian:trixie-slim

############################ builder ##########################################
# hadolint ignore=DL3006
FROM ${DEBIAN_IMAGE} AS builder

ARG JAVA_MAJOR=21
# Pack: All of Create 1.21.1 - v2.6 (client file 9164652, server pack file 9164660)
ARG PACK_VERSION=2.6
ARG SERVER_PACK_URL=https://mediafilez.forgecdn.net/files/9164/660/All_of_Create_v2.6_serverpack.zip
# SHA-1 published by CurseForge for file 9164660
ARG SERVER_PACK_SHA1=2ad6376911a23b28dd17fceaa31b4cbe4df7bd7b
# Loader: must equal MODLOADER_VERSION in the pack's variables.txt (checked below)
ARG MC_VERSION=1.21.1
ARG NEOFORGE_VERSION=21.1.256
# SHA-256 published by maven.neoforged.net (<installer>.jar.sha256)
ARG NEOFORGE_INSTALLER_SHA256=4aad931e8fd85fbf6ba35bab647811069d35ff010900492e39db1cb8b017348c

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# hadolint ignore=DL3008
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl unzip "openjdk-${JAVA_MAJOR}-jre-headless" \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /build
RUN curl -fsSL --retry 3 -o pack.zip "${SERVER_PACK_URL}" \
 && echo "${SERVER_PACK_SHA1}  pack.zip" | sha1sum -c - \
 && mkdir pack && unzip -q pack.zip -d pack && rm pack.zip
RUN grep -qx "MODLOADER_VERSION=${NEOFORGE_VERSION}" pack/variables.txt \
 || { echo "pack/variables.txt does not pin NeoForge ${NEOFORGE_VERSION}:"; grep -E '^(MINECRAFT|MODLOADER)' pack/variables.txt; exit 1; }

RUN curl -fsSL --retry 3 -o installer.jar \
      "https://maven.neoforged.net/releases/net/neoforged/neoforge/${NEOFORGE_VERSION}/neoforge-${NEOFORGE_VERSION}-installer.jar" \
 && echo "${NEOFORGE_INSTALLER_SHA256}  installer.jar" | sha256sum -c - \
 && mkdir -p /opt/aoc/server \
 && java -jar installer.jar --installServer /opt/aoc/server \
 && test -f "/opt/aoc/server/libraries/net/neoforged/neoforge/${NEOFORGE_VERSION}/unix_args.txt"

# Keep only what a dedicated server needs; drop launcher scripts / installers.
# hadolint ignore=DL3003
RUN cd pack \
 && cp -a mods config defaultconfigs datapacks server.properties server-icon.png /opt/aoc/server/ \
 && cd /opt/aoc/server \
 && rm -f run.sh run.bat user_jvm_args.txt ./*installer*.log \
 && printf 'PACK_VERSION=%s\nMC_VERSION=%s\nNEOFORGE_VERSION=%s\n' \
      "${PACK_VERSION}" "${MC_VERSION}" "${NEOFORGE_VERSION}" > /opt/aoc/VERSION

############################ runtime ##########################################
# hadolint ignore=DL3006
FROM ${DEBIAN_IMAGE}

ARG DEBIAN_IMAGE
ARG JAVA_MAJOR=21
ARG PACK_VERSION=2.6
ARG NEOFORGE_VERSION=21.1.256

LABEL org.opencontainers.image.title="all-of-create-server" \
      org.opencontainers.image.description="All of Create ${PACK_VERSION} (NeoForge ${NEOFORGE_VERSION}, MC 1.21.1) dedicated server" \
      org.opencontainers.image.base.name="${DEBIAN_IMAGE}"

# curl: only used for optional Mojang UUID lookups for OPS/WHITELIST.
# hadolint ignore=DL3008
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl tini "openjdk-${JAVA_MAJOR}-jre-headless" \
 && rm -rf /var/lib/apt/lists/* /usr/share/doc/* /usr/share/man/* \
 && groupadd -g 1000 minecraft \
 && useradd -u 1000 -g 1000 -d /data -M -s /usr/sbin/nologin minecraft \
 && mkdir -p /data && chown 1000:1000 /data

COPY --from=builder /opt/aoc /opt/aoc
COPY --chmod=0755 entrypoint.sh /usr/local/bin/entrypoint.sh
# `docker exec <ctr> mc-cmd say hello` -> types a command into the server console
# hadolint ignore=SC2016
RUN printf '#!/bin/sh\nprintf "%%s\\n" "$*" > "${CONSOLE_FIFO:-/tmp/minecraft-console}"\n' > /usr/local/bin/mc-cmd \
 && chmod 0755 /usr/local/bin/mc-cmd

ENV NEOFORGE_VERSION=${NEOFORGE_VERSION} \
    MEMORY=8G \
    EULA=""

USER 1000:1000
WORKDIR /data
VOLUME ["/data"]
EXPOSE 25565

# Modpacks take minutes to boot, hence the long start period. Pure-bash TCP
# probe: no extra packages needed.
HEALTHCHECK --start-period=10m --interval=30s --timeout=5s --retries=3 \
  CMD ["bash", "-c", "exec 3<>/dev/tcp/127.0.0.1/25565"]

# tini is PID 1 and forwards SIGTERM to entrypoint.sh, which types "stop" into
# the server console so the world is saved and logged on `docker stop`.
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
