#!/usr/bin/env bash
# Entrypoint for the All of Create server image.
#  - seeds /data from /opt/aoc/server without clobbering worlds or edited configs
#  - refreshes mods/ when the image's pack version changes (old mods backed up)
#  - applies optional server.properties overrides from env
#  - turns SIGTERM (via tini) into a console 'stop' so the world is saved cleanly
set -euo pipefail

SRC=/opt/aoc/server
DATA=/data
log() { printf '[entrypoint] %s\n' "$*"; }
die() { printf '[entrypoint] ERROR: %s\n' "$*" >&2; exit 1; }

# shellcheck disable=SC1091
. /opt/aoc/VERSION   # PACK_VERSION, MC_VERSION, NEOFORGE_VERSION

cd "$DATA"
[[ -w $DATA ]] || die "$DATA is not writable by uid $(id -u); chown the volume/bind mount to 1000:1000"

# ---------------------------------------------------------------- EULA
case "${EULA:-}" in
  [Tt][Rr][Uu][Ee]) echo "eula=true" > eula.txt ;;
  *) die "You must accept the Minecraft EULA (https://aka.ms/MinecraftEULA) by setting EULA=TRUE" ;;
esac

# ---------------------------------------------------------------- seeding
installed_version=""
[[ -f .aoc-pack-version ]] && installed_version=$(<.aoc-pack-version)
ts=$(date +%Y%m%d-%H%M%S)

if [[ -z $installed_version ]]; then
  log "First run: seeding $DATA from All of Create $PACK_VERSION"
elif [[ $installed_version != "$PACK_VERSION" ]]; then
  log "Pack upgrade detected: $installed_version -> $PACK_VERSION"
fi

# mods/: owned by the image. Replace on first run / version change.
if [[ $installed_version != "$PACK_VERSION" || ! -d mods ]]; then
  rm -rf mods.new && cp -a "$SRC/mods" mods.new   # copy first, swap atomically
  if [[ -d mods ]]; then
    mkdir -p backups
    mv mods "backups/mods-${installed_version:-unknown}-$ts"
    log "Old mods moved to backups/mods-${installed_version:-unknown}-$ts"
  fi
  mv mods.new mods
fi

# config/, datapacks/: copy only files that do not exist yet (keeps user edits,
# adds configs for newly added mods). RESEED_CONFIG=true forces a fresh copy.
if [[ ${RESEED_CONFIG:-false} == true && -d config ]]; then
  mkdir -p backups
  mv config "backups/config-$ts"
  log "RESEED_CONFIG=true: old config moved to backups/config-$ts"
fi
for d in config datapacks; do
  mkdir -p "$d"
  cp -a --update=none "$SRC/$d/." "$d/"
done
# defaultconfigs/ are templates for new worlds; always follow the pack.
rm -rf defaultconfigs && cp -a "$SRC/defaultconfigs" defaultconfigs
for f in server.properties server-icon.png; do
  [[ -e $f ]] || cp -a "$SRC/$f" "$f"
done

# libraries/ (NeoForge + vanilla server jar) stay in the image, read-only.
if [[ -e libraries && ! -L libraries ]]; then rm -rf libraries; fi
ln -sfn "$SRC/libraries" libraries

echo "$PACK_VERSION" > .aoc-pack-version

# ---------------------------------------------------------------- server.properties
set_prop() { # key value
  local key=$1 val=$2
  K="$key" V="$val" awk '
    BEGIN { k=ENVIRON["K"]; v=ENVIRON["V"]; done=0 }
    index($0, k "=") == 1 { print k "=" v; done=1; next }
    { print }
    END { if (!done) print k "=" v }
  ' server.properties > server.properties.tmp && mv server.properties.tmp server.properties
}
[[ -n ${MOTD:-} ]]              && set_prop motd "$MOTD"
[[ -n ${DIFFICULTY:-} ]]        && set_prop difficulty "$DIFFICULTY"
[[ -n ${MAX_PLAYERS:-} ]]       && set_prop max-players "$MAX_PLAYERS"
[[ -n ${VIEW_DISTANCE:-} ]]     && set_prop view-distance "$VIEW_DISTANCE"
[[ -n ${SIMULATION_DISTANCE:-} ]] && set_prop simulation-distance "$SIMULATION_DISTANCE"
[[ -n ${ONLINE_MODE:-} ]]       && set_prop online-mode "${ONLINE_MODE,,}"
[[ -n ${LEVEL_SEED:-} ]]        && set_prop level-seed "$LEVEL_SEED"
[[ -n ${ENABLE_WHITELIST:-} ]]  && { set_prop white-list "${ENABLE_WHITELIST,,}"; set_prop enforce-whitelist "${ENABLE_WHITELIST,,}"; }
set_prop server-port 25565

if [[ -n ${RCON_PASSWORD:-} ]]; then
  set_prop enable-rcon true
  set_prop rcon.password "$RCON_PASSWORD"
  set_prop rcon.port "${RCON_PORT:-25575}"
else
  set_prop enable-rcon false
fi

# ---------------------------------------------------------------- ops / whitelist
online_mode=$(grep -m1 '^online-mode=' server.properties | cut -d= -f2 || true)

offline_uuid() { # Java UUID.nameUUIDFromBytes("OfflinePlayer:<name>")
  local h; h=$(printf 'OfflinePlayer:%s' "$1" | md5sum | cut -c1-32)
  local b6=$(( (16#${h:12:2} & 0x0f) | 0x30 )) b8=$(( (16#${h:16:2} & 0x3f) | 0x80 ))
  h="${h:0:12}$(printf '%02x' "$b6")${h:14:2}$(printf '%02x' "$b8")${h:18}"
  printf '%s-%s-%s-%s-%s' "${h:0:8}" "${h:8:4}" "${h:12:4}" "${h:16:4}" "${h:20:12}"
}
player_uuid() {
  if [[ $online_mode == false ]]; then offline_uuid "$1"; return; fi
  local id
  id=$(curl -fsS -m 10 "https://api.mojang.com/users/profiles/minecraft/$1" 2>/dev/null \
        | sed -n 's/.*"id" *: *"\([0-9a-fA-F]\{32\}\)".*/\1/p') || true
  [[ -n $id ]] || return 1
  printf '%s-%s-%s-%s-%s' "${id:0:8}" "${id:8:4}" "${id:12:4}" "${id:16:4}" "${id:20:12}"
}
write_players() { # file csv extra-json
  local file=$1 csv=$2 extra=$3 out="" name uuid
  IFS=',' read -ra names <<< "$csv"
  for name in "${names[@]}"; do
    name=${name//[[:space:]]/}
    [[ -n $name ]] || continue
    [[ $name =~ ^[A-Za-z0-9_]{1,16}$ ]] || { log "skipping invalid player name '$name'"; continue; }
    if ! uuid=$(player_uuid "$name"); then log "could not resolve UUID for '$name', skipping"; continue; fi
    out+="${out:+,}{\"uuid\":\"$uuid\",\"name\":\"$name\"$extra}"
  done
  printf '[%s]\n' "$out" > "$file"
  log "wrote $file"
}
[[ -n ${OPS:-} ]]       && write_players ops.json "$OPS" ",\"level\":${OPS_LEVEL:-4},\"bypassesPlayerLimit\":false"
[[ -n ${WHITELIST:-} ]] && write_players whitelist.json "$WHITELIST" ""

# ---------------------------------------------------------------- JVM
MEMORY=${MEMORY:-8G}
INIT_MEMORY=${INIT_MEMORY:-$MEMORY}
[[ $MEMORY =~ ^[0-9]+[MmGg]$ ]] || die "MEMORY must look like 8G or 6144M (got '$MEMORY')"

# Guide flags (modready.gg) + the remaining Aikar G1 tunings that apply to JDK 21.
jvm_flags=(
  "-Xms${INIT_MEMORY}" "-Xmx${MEMORY}"
  -XX:+UseG1GC -XX:+ParallelRefProcEnabled -XX:MaxGCPauseMillis=200
  -XX:+UnlockExperimentalVMOptions -XX:+DisableExplicitGC
  -XX:G1NewSizePercent=30 -XX:G1MaxNewSizePercent=40 -XX:G1HeapRegionSize=8M
  -XX:G1ReservePercent=20 -XX:G1HeapWastePercent=5 -XX:G1MixedGCCountTarget=4
  -XX:InitiatingHeapOccupancyPercent=15 -XX:G1MixedGCLiveThresholdPercent=90
  -XX:SurvivorRatio=32 -XX:+PerfDisableSharedMem -XX:MaxTenuringThreshold=1
  -Dlog4j2.formatMsgNoLookups=true
)
[[ ${ALWAYS_PRE_TOUCH:-false} == true ]] && jvm_flags+=(-XX:+AlwaysPreTouch)
# shellcheck disable=SC2206  # JVM_OPTS is intentionally word-split
[[ -n ${JVM_OPTS:-} ]] && jvm_flags+=(${JVM_OPTS})

log "Starting All of Create $PACK_VERSION (MC $MC_VERSION, NeoForge $NEOFORGE_VERSION), heap $INIT_MEMORY/$MEMORY"

# Java reads its console from a FIFO. On SIGTERM/SIGINT (docker stop, forwarded
# by tini) we type "stop" into it, so the server runs its normal shutdown path
# and logs "Saving worlds" before exiting. (A raw SIGTERM to the JVM also saves,
# but Log4j is already shut down by then, so nothing is logged.)
CONSOLE_FIFO=${CONSOLE_FIFO:-/tmp/minecraft-console}
rm -f "$CONSOLE_FIFO" && mkfifo -m 600 "$CONSOLE_FIFO"
exec 3<>"$CONSOLE_FIFO"   # held open read/write so the server never sees EOF

java "${jvm_flags[@]}" \
  "@libraries/net/neoforged/neoforge/${NEOFORGE_VERSION}/unix_args.txt" \
  nogui "$@" <&3 &
java_pid=$!

# Forward `docker attach` input (stdin_open: true) to the console.
if [[ ! -t 0 ]] && ! [[ /dev/stdin -ef /dev/null ]]; then
  cat >&3 &
fi

stopping=false
# shellcheck disable=SC2317  # invoked via trap
on_stop() {
  $stopping && return
  stopping=true
  log "Received stop signal, sending 'stop' to the server console"
  echo stop >&3
}
trap on_stop TERM INT

# `wait` returns early when a trapped signal arrives; keep waiting for Java.
rc=0
while kill -0 "$java_pid" 2>/dev/null; do
  wait "$java_pid" && rc=0 || rc=$?
done
log "Server exited with code $rc"
exit "$rc"
