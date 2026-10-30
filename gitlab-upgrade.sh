#!/usr/bin/env bash
# gitlab-upgrade.sh — guided, gated upgrade for GitLab Linux package (Omnibus)
# installs on Debian/Ubuntu. Automates every step a machine can verify and
# stops at the steps only a human can do (snapshot, off-server copy, browser).
#
#   curl -fsSLO https://raw.githubusercontent.com/princeppy/gitlab-upgrade-kit/main/gitlab-upgrade.sh
#   sudo bash gitlab-upgrade.sh help
#
# Copyright (c) 2026 Prince PARK. All rights reserved — see LICENSE. No warranty.
set -Eeuo pipefail

readonly KIT_VERSION="1.0.0"
readonly VERSION_FILE="/opt/gitlab/embedded/service/gitlab-rails/VERSION"
readonly GITLAB_RB="/etc/gitlab/gitlab.rb"
readonly BACKUP_DIR="/var/opt/gitlab/backups"
readonly STATE_DIR="${GUK_STATE_DIR:-/root/gitlab-upgrade}"
readonly REQUIRED_STOP_MINORS="2 5 8 11"
EXTRA_STOPS="${GUK_EXTRA_STOPS:-}"            # e.g. "18.0" if the official path tool lists it
readonly DISK_HEADROOM_GB="${GUK_DISK_HEADROOM_GB:-8}"
readonly MIGRATION_TIMEOUT_MIN="${GUK_MIGRATION_TIMEOUT_MIN:-60}"
readonly HEALTH_TIMEOUT_SEC="${GUK_HEALTH_TIMEOUT_SEC:-600}"
readonly JOURNAL_KEEP="${GUK_JOURNAL_KEEP:-500M}"
readonly BACKUP_KEEP_DAYS="${GUK_BACKUP_KEEP_DAYS:-7}"
readonly SELF="${GUK_SELF:-gitlab-upgrade.sh}"   # for messages; \$0 is "bash" under curl | bash

ASSUME_YES=false
APPLY=false
NO_TMUX=false
TARGET="latest"
PKG=""

# ---------------------------------------------------------------- output ----

if [[ -t 1 ]]; then
  C_R=$'\e[31m' C_G=$'\e[32m' C_Y=$'\e[33m' C_B=$'\e[1;34m' C_0=$'\e[0m'
else
  C_R="" C_G="" C_Y="" C_B="" C_0=""
fi

phase() { printf '\n%s== %s ==%s\n' "$C_B" "$*" "$C_0"; }
info()  { printf '   %s\n' "$*"; }
ok()    { printf '%s  ✔ %s%s\n' "$C_G" "$*" "$C_0"; }
warn()  { printf '%s  ! %s%s\n' "$C_Y" "$*" "$C_0"; }
die()   { trap - ERR; printf '%s  ✘ %s%s\n' "$C_R" "$*" "$C_0" >&2; result "${CURRENT_PHASE:-main}" fail; exit 1; }
# Machine-readable line for AI agents / CI wrappers.
result() { printf '::result phase=%s status=%s%s\n' "$1" "$2" "${3:+ detail=$3}"; }

# Read from the terminal even when the script itself arrives on stdin (curl | bash).
ask() {
  local prompt="$1" reply
  { : </dev/tty; } 2>/dev/null || die "No terminal for input. Re-run interactively, or pass --yes."
  read -r -p "$prompt" reply </dev/tty
  printf '%s' "$reply"
}

confirm() {
  $ASSUME_YES && return 0
  [[ "$(ask "   $1 [y/N] ")" =~ ^[Yy]$ ]]
}

# Risky decisions: a person must answer, --yes never does.
confirm_human() {
  $ASSUME_YES && die "Needs a human decision: $1 Re-run without --yes."
  [[ "$(ask "   $1 [y/N] ")" =~ ^[Yy]$ ]]
}

# Human-only step. Never auto-skipped by --yes: an agent must set GUK_CONFIRM_<NAME>=yes
# only after a human has actually done the work.
human_gate() {
  local name="$1" text="$2" var="GUK_CONFIRM_${1^^}" marker
  marker="$STATE_DIR/gate-${name}-$(current_ver)"
  if [[ -f "$marker" ]]; then ok "Gate '${name}' already confirmed ($(cat "$marker"))"; return 0; fi
  phase "HUMAN STEP — ${name}"
  printf '%s\n' "$text" | sed 's/^/   /'
  if [[ "${!var:-}" == "yes" ]]; then
    date '+%F %T via env' >"$marker"; ok "Confirmed via ${var}=yes"; return 0
  fi
  if $ASSUME_YES; then
    warn "Waiting for a human. Do the step above, then re-run with ${var}=yes."
    result "gate-${name}" waiting "set ${var}=yes after doing it"
    exit 2
  fi
  [[ "$(ask "   Type DONE when finished: ")" == "DONE" ]] || die "Gate '${name}' not confirmed."
  date '+%F %T interactive' >"$marker"
  ok "Gate '${name}' confirmed"
}

# ------------------------------------------------- pure version helpers ----
# Covered by tests/test_path.sh — keep them free of side effects.

ver_base() { sed -E 's/-.*$//' <<<"$1"; }
minor_of() { cut -d. -f1,2 <<<"$1"; }
ver_le()   { [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" == "$1" ]]; }
ver_lt()   { [[ "$1" != "$2" ]] && ver_le "$1" "$2"; }

is_stop_minor() {
  local minor="$1" m
  for m in $EXTRA_STOPS; do [[ "$m" == "$minor" ]] && return 0; done
  for m in $REQUIRED_STOP_MINORS; do [[ "${minor#*.}" == "$m" ]] && return 0; done
  return 1
}

# latest_patch MINOR <versions  → newest M.m.x in the list (empty if none)
latest_patch() { grep -E "^${1//./\\.}\.[0-9]+$" | sort -V | tail -1 || true; }

# resolve_target TARGET <versions  → full version. TARGET: latest | M.m | M.m.p
resolve_target() {
  local target="$1" versions; versions="$(cat)"
  case "$target" in
    latest) sort -V <<<"$versions" | tail -1 ;;
    *.*.*)  grep -qxF "$target" <<<"$versions" && echo "$target" || true ;;
    *.*)    latest_patch "$target" <<<"$versions" ;;
    *)      true ;;
  esac
}

# compute_path CURRENT TARGET <versions  → one version per line, in install order.
compute_path() {
  local cur="$1" target="$2" versions minor top
  versions="$(cat)"
  ver_lt "$cur" "$target" || return 0
  # Sitting on a stop but not its newest patch: take the patch first.
  minor="$(minor_of "$cur")"
  if is_stop_minor "$minor" && [[ "$minor" != "$(minor_of "$target")" ]]; then
    top="$(latest_patch "$minor" <<<"$versions")"
    [[ -n "$top" ]] && ver_lt "$cur" "$top" && echo "$top"
  fi
  while read -r minor; do
    ver_lt "$(minor_of "$cur")" "$minor" || continue
    ver_lt "$minor" "$(minor_of "$target")" || continue
    is_stop_minor "$minor" && latest_patch "$minor" <<<"$versions"
  done < <(sed -E 's/\.[0-9]+$//' <<<"$versions" | sort -uV)
  echo "$target"
}

# ---------------------------------------------------------- environment ----

need_root()    { [[ $EUID -eq 0 ]] || die "Run as root (sudo bash $SELF ...)."; }
current_ver_raw() { tr -d '[:space:]' <"$VERSION_FILE"; }    # e.g. 19.5.3 or 19.5.3-ee
current_ver()  { ver_base "$(current_ver_raw)"; }
psql_val()     { local v; v="$(gitlab-psql -At -c "$1" 2>/dev/null)" || return 1; tr -d '[:space:]' <<<"$v"; }
pkg_installed(){ dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -qE "(install|hold) ok installed"; }
free_gb()      { df -BG --output=avail / | tail -1 | tr -dc '0-9'; }
external_url() { grep -E "^\s*external_url" "$GITLAB_RB" | head -1 | sed -E "s/.*['\"](.*)['\"].*/\1/"; }

detect_package() {
  if [[ ! -f "$VERSION_FILE" ]] || ! command -v gitlab-ctl >/dev/null; then
    die "No GitLab Linux package found. Docker/Helm installs are out of scope."
  fi
  if pkg_installed gitlab-ee; then PKG=gitlab-ee; elif pkg_installed gitlab-ce; then PKG=gitlab-ce
  else die "Neither gitlab-ce nor gitlab-ee is installed via dpkg."; fi
}

available_versions() {
  apt-cache madison "$PKG" | awk -F'|' '{gsub(/ /,"",$2); print $2}' \
    | sed -E 's/-.*$//' | sort -uV
}

pkg_version_string() {  # base version → exact apt version string (e.g. 19.5.3-ce.0)
  apt-cache madison "$PKG" | awk -F'|' '{gsub(/ /,"",$2); print $2}' | grep -E "^${1//./\\.}-(ce|ee)\.[0-9]+$" | head -1
}

upgrade_path() {
  local cur target m
  cur="$(current_ver)"
  if ver_lt "$cur" 17.5.0 && [[ -z "$EXTRA_STOPS" ]]; then
    die "Below 17.5 the stops differ from x.2/5/8/11. Get the path from the official tool and set GUK_EXTRA_STOPS."
  fi
  target="$(available_versions | resolve_target "$TARGET")"
  [[ -n "$target" ]] || die "Target '$TARGET' not found in the apt repo."
  ver_lt "$target" "$cur" && die "Target $target is older than the installed $cur."
  for m in $EXTRA_STOPS; do
    [[ -n "$(available_versions | latest_patch "$m")" ]] || die "Extra stop $m is not in the apt repo."
  done
  available_versions | compute_path "$cur" "$target"
}

services_down() { gitlab-ctl status 2>/dev/null | grep -v '^run:' || true; }

# Prints the number of "down" migrations, or "?" if rake could not report (fails every == 0 check).
pending_schema() {
  local out
  out="$(gitlab-rake db:migrate:status 2>&1)" || { echo "?"; return 0; }
  grep -qE '^ +up ' <<<"$out" || { echo "?"; return 0; }
  grep -c '^  down' <<<"$out" || true
}

bbm_unfinished() { psql_val "SELECT count(*) FROM batched_background_migrations WHERE status NOT IN (3,6);" || echo "?"; }
bbm_failed()     { psql_val "SELECT count(*) FROM batched_background_migrations WHERE status = 4;" || echo "?"; }

readiness_ok() {
  local url host port scheme
  url="$(external_url)"; scheme="${url%%://*}"; host="${url#*://}"; host="${host%%/*}"
  port=443; [[ "$scheme" == "http" ]] && port=80
  if [[ "$host" == *:* ]]; then port="${host##*:}"; host="${host%:*}"; fi
  curl -fsk --max-time 10 --resolve "${host}:${port}:127.0.0.1" "${url%/}/-/readiness" \
    | grep -q '"status":"ok"'
}

wait_healthy() {
  local waited=0
  info "Waiting for services and /-/readiness (up to ${HEALTH_TIMEOUT_SEC}s)..."
  until [[ -z "$(services_down)" ]] && readiness_ok; do
    (( waited >= HEALTH_TIMEOUT_SEC )) && { services_down; die "GitLab not healthy after ${waited}s."; }
    sleep 10; waited=$((waited + 10))
  done
  ok "GitLab healthy after ~${waited}s"
}

refresh_gitlab_keyrings() {
  local list ring url
  for list in /etc/apt/sources.list.d/*gitlab*.list; do
    [[ -f "$list" ]] || continue
    ring="$(grep -oE 'signed-by=[^] ]+' "$list" | head -1 | cut -d= -f2)"
    url="$(grep -oE 'https://packages\.gitlab\.com/[^/]+/[^/ ]+' "$list" | head -1)"
    [[ -n "$ring" && -n "$url" ]] || continue
    info "Refreshing $ring from $url/gpgkey"
    curl -fsSL "$url/gpgkey" | gpg --dearmor --batch --yes -o "$ring.new" || die "Key download failed for $url."
    gpg --show-keys "$ring.new" >/dev/null 2>&1 || { rm -f -- "$ring.new"; die "Downloaded key for $url is not a valid keyring."; }
    mv -- "$ring.new" "$ring"
  done
}

apt_refresh() {
  local out
  out="$(apt-get update 2>&1 || true)"
  if grep -q EXPKEYSIG <<<"$out"; then
    warn "GitLab repo signing key expired (EXPKEYSIG) — apt is using a stale index."
    confirm_human "Replace the GitLab repo keyrings with the keys served by packages.gitlab.com?" \
      || die "Cannot continue with a stale index."
    refresh_gitlab_keyrings
    out="$(apt-get update 2>&1 || true)"
  fi
  if grep -E '^(Err|W: GPG|E:)' <<<"$out" | grep -qi gitlab; then
    grep -E '^(Err|W:|E:)' <<<"$out"; die "apt-get update failed for a GitLab repo."
  fi
  ok "apt index refreshed (GitLab repos clean)"
}

# ---------------------------------------------------------------- phases ----

cmd_status() {
  CURRENT_PHASE=status
  phase "Status"
  info "Kit $KIT_VERSION · $PKG $(current_ver) · PostgreSQL $(psql_val 'SHOW server_version;')"
  info "Disk free: $(free_gb) GB · $(df -h / | awk 'NR==2{print $5}') used"
  local down; down="$(services_down)"
  if [[ -z "$down" ]]; then ok "All services running"; else warn "Services not running:"; info "$down"; fi
  info "Schema migrations pending: $(pending_schema) · background migrations unfinished: $(bbm_unfinished)"
  info "Held packages: $(apt-mark showhold | tr '\n' ' ')"
  result status pass
}

preflight_state() {  # prints one warning per problem; returns the count
  local fails=0 down
  down="$(services_down)"
  if [[ -z "$down" ]]; then ok "All services running"; else warn "Already down before upgrading:"; info "$down"; fails=$((fails+1)); fi
  info "PostgreSQL $(psql_val 'SHOW server_version;') — check the version notes for each major's minimum."
  if grep -qE '^\s*git_data_dirs' "$GITLAB_RB"; then
    warn "git_data_dirs is set — removed in 18.0; migrate to repositories_storages first."; fails=$((fails+1))
  fi
  if [[ "$(pending_schema)" == 0 ]]; then ok "No pending schema migrations"; else warn "Schema migrations pending"; fails=$((fails+1)); fi
  if [[ "$(bbm_unfinished)" == 0 ]]; then ok "Background migrations all finished"
  else warn "Background migrations unfinished: $(bbm_unfinished)"; fails=$((fails+1)); fi
  if swapon --show | grep -q .; then ok "Swap present ($(free -h | awk '/Swap/{print $2}'))"
  else warn "No swap. See SOP E.1 (4 GB swapfile, swappiness 10)."; fi
  info "Kubernetes agents: $(psql_val 'SELECT count(*) FROM cluster_agents;') (19.5+ advertises KAS over gRPC)"
  return "$fails"
}

cmd_preflight() {
  CURRENT_PHASE=preflight
  local fails=0 path cur need
  phase "Preflight (read-only, SOP phases D–E)"
  grep -qiE '^ID(_LIKE)?=.*(debian|ubuntu)' /etc/os-release || die "Debian/Ubuntu only."
  cur="$(current_ver)"; ok "Installed: $PKG $cur"
  if command -v docker >/dev/null && docker ps -a --format '{{.Image}}' 2>/dev/null | grep -qi 'gitlab/gitlab'; then
    warn "A GitLab Docker container also exists — make sure you are upgrading the right instance."
  fi
  preflight_state || fails=$?
  apt_refresh
  path="$(upgrade_path)"
  if [[ -z "$path" ]]; then ok "Already on the target version — nothing to upgrade."
  else
    ok "Upgrade path: $cur → $(paste -sd' ' <<<"$path" | sed 's/ / → /g')"
    print_version_notes "$cur" "$(tail -1 <<<"$path")"
  fi
  need=$(( $(du -s --block-size=1G /var/opt/gitlab 2>/dev/null | cut -f1) + DISK_HEADROOM_GB ))
  if (( $(free_gb) >= need )); then ok "Disk: $(free_gb) GB free (need ~${need} GB)"
  else warn "Disk: $(free_gb) GB free, need ~${need} GB — run: $SELF cleanup"; fails=$((fails+1)); fi
  if (( fails == 0 )); then result preflight pass; else result preflight warn "$fails"; warn "$fails item(s) need attention."; fi
}

print_version_notes() {
  local major
  info "Read the upgrade notes for every major you touch before continuing:"
  for major in $(seq "${1%%.*}" "${2%%.*}"); do
    info "  https://docs.gitlab.com/update/versions/gitlab_${major}_changes/"
  done
  info "  Cross-check the path: https://gitlab-com.gitlab.io/support/toolbox/upgrade-path/"
}

cleanup_item() {  # cleanup_item LABEL SIZE FUNCTION [ARG]
  info "• $1 — ${2:-unknown size}"
  if $APPLY && confirm_human "Remove: $1?"; then "$3" "${4:-}" && ok "Removed: $1"; fi
}

prune_images()     { docker image prune -a -f >/dev/null; }
runner_cache_volumes() { docker volume ls -q --filter dangling=true | grep -E '^runner-[0-9a-f]+-cache-' || true; }
prune_volumes()    { runner_cache_volumes | xargs -r docker volume rm >/dev/null; }
vacuum_journal()   { journalctl --vacuum-size="$JOURNAL_KEEP" >/dev/null; }
remove_file()      { rm -f -- "$1"; }
remove_prom_data() { find /var/opt/gitlab/prometheus/data -mindepth 1 -delete; }

docker_reclaimable() { docker system df --format '{{.Type}}|{{.Reclaimable}}' | awk -F'|' -v t="$1" '$1 ~ t {print $2}'; }

cmd_cleanup() {
  CURRENT_PHASE=cleanup
  local f cur
  phase "Disk cleanup ($($APPLY && echo apply || echo 'report only — add --apply to remove'))"
  info "Disk before: $(df -h / | awk 'NR==2{print $3" used, "$4" free ("$5")"}')"
  if command -v docker >/dev/null; then
    if [[ -z "$(docker ps -q)" ]]; then
      cleanup_item "unused Docker images" "$(docker_reclaimable Images)" prune_images
      cleanup_item "unused GitLab Runner cache volumes ($(runner_cache_volumes | grep -c . || true) volumes; other volumes untouched)" "" prune_volumes
    else warn "Docker containers are running (CI jobs?) — skipping Docker cleanup."; fi
  fi
  if [[ -d /var/opt/gitlab/prometheus/data ]] && ! gitlab-ctl status prometheus 2>/dev/null | grep -q '^run'; then
    cleanup_item "Prometheus data (service not running)" "$(du -sh /var/opt/gitlab/prometheus/data | cut -f1)" remove_prom_data
  fi
  cleanup_item "systemd journal above ${JOURNAL_KEEP}" "$(journalctl --disk-usage | grep -oE '[0-9.]+[KMGT]')" vacuum_journal
  cur="$(current_ver_raw)"
  for f in "$BACKUP_DIR"/*_gitlab_backup.tar; do
    [[ -f "$f" && "$f" != *"_${cur}_gitlab_backup.tar" ]] || continue
    if [[ -n "$(find "$f" -mtime -"$BACKUP_KEEP_DAYS")" ]] || grep -qF "$f" "$STATE_DIR/last-backup.sha256" 2>/dev/null; then
      info "• keeping $(basename "$f") — the latest pre-upgrade backup or younger than ${BACKUP_KEEP_DAYS} days"; continue
    fi
    cleanup_item "backup from another version: $(basename "$f")" "$(du -sh "$f" | cut -f1)" remove_file "$f"
  done
  info "Never touched: repositories, database, shared/* (artifacts, registry, packages), /etc/gitlab."
  info "Disk after: $(df -h / | awk 'NR==2{print $3" used, "$4" free ("$5")"}')"
  result cleanup pass
}

backup_config() {  # backup_config DEST
  cp -a /etc/gitlab "$1" || die "Copying /etc/gitlab failed."
  diff -rq /etc/gitlab "$1" >/dev/null || die "The /etc/gitlab copy differs from the original."
  [[ -f "$1/gitlab-secrets.json" ]] || die "gitlab-secrets.json missing from the copy."
}

cmd_backup() {
  CURRENT_PHASE=backup
  local d est cfg tar sum
  phase "Backup (SOP phase F)"
  d="$(date +%Y%m%d-%H%M)"
  # A new backup invalidates earlier human confirmations: it must be copied off again.
  rm -f -- "$STATE_DIR"/gate-* "$STATE_DIR/offsite.txt" "$STATE_DIR/last-backup.sha256"
  cfg="$STATE_DIR/etc-gitlab-$d"
  backup_config "$cfg"; ok "Config + secrets copied to $cfg"
  est=$(du -s --block-size=1G /var/opt/gitlab/git-data /var/opt/gitlab/gitlab-rails/shared /var/opt/gitlab/postgresql 2>/dev/null | awk '{s+=$1} END{print s+0}')
  (( $(free_gb) >= est * 2 + 2 )) || die "Only $(free_gb) GB free; STRATEGY=copy needs ~$((est * 2 + 2)) GB. Run cleanup first."
  info "Running gitlab-backup create STRATEGY=copy (~${est} GB of data; progress in $STATE_DIR/backup-$d.log)..."
  gitlab-backup create STRATEGY=copy >"$STATE_DIR/backup-$d.log" 2>&1 || { tail -20 "$STATE_DIR/backup-$d.log"; die "gitlab-backup failed."; }
  # shellcheck disable=SC2012  # backup names are GitLab-generated, no odd characters
  tar="$(ls -t "$BACKUP_DIR"/*_gitlab_backup.tar | head -1)"
  [[ "$tar" == *"_$(current_ver_raw)_gitlab_backup.tar" ]] || die "Newest backup is not for $(current_ver_raw): $tar"
  sum="$(sha256sum "$tar" | cut -d' ' -f1)"
  printf '%s  %s\n' "$sum" "$tar" >"$STATE_DIR/last-backup.sha256"
  ok "Backup: $(basename "$tar") ($(du -sh "$tar" | cut -f1)), sha256 ${sum:0:12}…"
  offsite_text "$tar" "$cfg" "$sum" >"$STATE_DIR/offsite.txt"
  phase "Next: copy off the server"
  sed 's/^/   /' "$STATE_DIR/offsite.txt"
  result backup pass "$(basename "$tar")"
}

offsite_text() {  # offsite_text TAR CFG SHA256
  local tar="$1" cfg="$2" sum="$3"
  cat <<TXT
Copy the backup AND the config folder to another machine, then verify:

  D=\$(date +%Y%m%d); mkdir -p ~/gitlab-backup-\$D
  scp <ssh-alias>:$tar ~/gitlab-backup-\$D/
  scp -r <ssh-alias>:$cfg ~/gitlab-backup-\$D/
  shasum -a 256 ~/gitlab-backup-\$D/$(basename "$tar")   # must be ${sum}
  chmod -R go-rwx ~/gitlab-backup-\$D

The config folder holds gitlab-secrets.json and TLS keys. Without it the backup cannot
decrypt CI variables, 2FA or tokens. Keep it out of synced folders.
Budget time: ~45 min for 6 GB at 2 MB/s.
TXT
}

require_backup() {  # a kit backup for the installed version must exist and still match its checksum
  local rec="$STATE_DIR/last-backup.sha256" tar
  [[ -f "$rec" ]] || die "No backup recorded by this kit. Run: $SELF backup"
  tar="$(awk '{print $2}' "$rec")"
  [[ -f "$tar" && "$tar" == *"_$(current_ver_raw)_gitlab_backup.tar" ]] \
    || die "Recorded backup $tar is missing or not for $(current_ver_raw). Run: $SELF backup"
  info "Checking backup checksum..."
  sha256sum -c --status "$rec" || die "Backup $tar no longer matches its recorded checksum."
  ok "Backup present: $(basename "$tar")"
}

offsite_gate() {
  require_backup
  human_gate offsite "$(cat "$STATE_DIR/offsite.txt")"
}

snapshot_instructions() {
  phase "Next: snapshot"
  sed 's/^/   /' <<TXT
Take a disk snapshot with the server shut down cleanly:
  1. On the server: shutdown -h now     (not a hard 'Power off' in the console)
  2. In your cloud console wait for 'Off', then snapshot it as
     pre-upgrade-$(current_ver)-$(date +%d%b%Y)
  3. Power on, reconnect, start tmux, wait ~3 minutes, then:
     sudo bash $SELF resume
TXT
}

require_session() {
  $NO_TMUX && return 0
  [[ -n "${TMUX:-}${STY:-}" ]] || die "Not inside tmux/screen. A dropped SSH session mid-install breaks the package.
     Run: tmux new -s gitlab   then re-run this command (or pass --no-tmux)."
}

install_pinned() {  # install_pinned VERSION
  local exact plan
  exact="$(pkg_version_string "$1")"
  [[ -n "$exact" ]] || die "$PKG $1 not found in apt."
  plan="$(apt-get -s install --allow-change-held-packages "$PKG=$exact" 2>&1)" \
    || { info "$plan"; die "apt cannot install $PKG=$exact (simulation failed)."; }
  plan="$(grep -E '^(Inst|Remv)' <<<"$plan" || true)"
  if [[ "$(grep -c . <<<"$plan")" -ne 1 ]] || ! grep -q "^Inst $PKG " <<<"$plan"; then
    warn "apt plan is not exactly one install of $PKG:"; info "$plan"
    confirm_human "Proceed with this apt plan?" || die "Aborted: unexpected apt plan."
  fi
  info "Installing $PKG=$exact (download + pre-install DB dump + reconfigure; do not interrupt)..."
  # force-confold keeps your gitlab.rb; NEEDRESTART_SUSPEND avoids a second full restart on Ubuntu.
  DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1 apt-get install -y \
    --allow-change-held-packages -o Dpkg::Options::=--force-confold "$PKG=$exact"
}

restart_redis_if_stale() {
  local running installed
  running="$(gitlab-redis-cli info server 2>/dev/null | awk -F: '/^redis_version/{print $2}' | tr -d '\r')"
  installed="$(/opt/gitlab/embedded/bin/redis-server --version | grep -oE 'v=[0-9.]+' | cut -d= -f2)"
  if [[ -n "$running" && "$running" != "$installed" ]]; then
    warn "Redis running $running, installed $installed — restarting (signs users out)."
    gitlab-ctl restart redis
  else ok "Redis $installed (no restart needed)"; fi
}

wait_background_migrations() {
  local waited=0 left finalized=false
  while :; do
    [[ "$(bbm_failed)" == 0 ]] || die "A batched background migration FAILED. See /admin/background_migrations."
    left="$(bbm_unfinished)"
    [[ "$left" == 0 ]] && { ok "Background migrations finished"; return 0; }
    if (( waited >= MIGRATION_TIMEOUT_MIN * 60 )); then
      warn "$left background migration(s) still running after ${MIGRATION_TIMEOUT_MIN} min."
      if ! $finalized && { [[ "${GUK_FINALIZE:-}" == yes ]] || { ! $ASSUME_YES && confirm "Force them now with finalize_all (fine on small instances with no users)?"; }; }; then
        gitlab-rake "gitlab:background_migrations:finalize_all[main]" || die "finalize_all failed — investigate before continuing."
        finalized=true; waited=0; continue
      fi
      die "Migrations unfinished. Wait and re-run, or set GUK_FINALIZE=yes."
    fi
    info "$left background migration(s) running... (${waited}s)"
    sleep 30; waited=$((waited + 30))
  done
}

# Runs before every install, so a re-run after a timed-out gate can never stack a new hop
# on top of unfinished migrations.
pre_hop_gate() {
  [[ -z "$(services_down)" ]] || { services_down; die "Services are down — fix before installing."; }
  [[ "$(pending_schema)" == 0 ]] || die "Schema migrations pending (or rake failed) — not installing."
  wait_background_migrations
}

hop_gate() {  # SOP G.3 — must pass before the next hop
  local want="$1"
  [[ "$(current_ver)" == "$want" ]] || die "Version is $(current_ver), expected $want."
  ok "Version $want installed"
  wait_healthy
  [[ "$(pending_schema)" == 0 ]] || die "Schema migrations still pending after install."
  ok "No pending schema migrations"
  restart_redis_if_stale
  wait_background_migrations
}

cmd_upgrade() {
  CURRENT_PHASE=upgrade
  local path hop n=0 total
  phase "Upgrade (SOP phase G)"
  require_session
  offsite_gate
  human_gate snapshot "Confirm a disk snapshot of this server was taken (ideally powered off)
after the backup and before this upgrade. Note its name/ID for the rollback plan."
  wait_healthy
  apt_refresh
  path="$(upgrade_path)"
  [[ -n "$path" ]] || { ok "Already on the target version."; result upgrade pass noop; return 0; }
  total="$(grep -c . <<<"$path")"
  info "Path: $(current_ver) → $(paste -sd' ' <<<"$path" | sed 's/ / → /g')"
  if grep -qE '^\s*git_data_dirs' "$GITLAB_RB" && ver_lt "$(current_ver)" 18.0.0 && ! ver_lt "$(tail -1 <<<"$path")" 18.0.0; then
    die "git_data_dirs is removed in 18.0. Migrate to gitlab_rails['repositories_storages'] first."
  fi
  if $ASSUME_YES && [[ "$TARGET" == latest && "${path##*$'\n'}" != "$(current_ver | cut -d. -f1)".* ]]; then
    die "--yes with target 'latest' would cross a major version. Pass --target explicitly."
  fi
  confirm "Start $total hop(s)? Backup and snapshot are done." || die "Aborted by user."
  for hop in $path; do
    n=$((n + 1)); phase "Hop $n/$total → $hop"
    pre_hop_gate
    install_pinned "$hop"
    hop_gate "$hop"
    result "hop-$n" pass "$hop"
  done
  result upgrade pass "$(current_ver)"
}

pages_check() {
  local group domain code
  grep -qE "^\s*pages_external_url" "$GITLAB_RB" || { info "Pages not configured — skipped."; return 0; }
  domain="$(grep -E '^\s*pages_external_url' "$GITLAB_RB" | sed -E "s/.*['\"]https?:\/\/([^/'\"]+).*/\1/")"
  group="$(gitlab-psql -At -c "SELECT n.path FROM pages_deployments d JOIN projects p ON p.id=d.project_id JOIN namespaces n ON n.id=p.namespace_id WHERE d.deleted_at IS NULL LIMIT 1;" 2>/dev/null | head -1)"
  group="${group:-routing-test}"
  code="$(curl -s -o /dev/null -w '%{http_code}' -H "Host: ${group}.${domain}" http://127.0.0.1)"
  case "$code" in
    200|302|404) ok "Pages answers for ${group}.<pages-domain>: HTTP $code" ;;
    *) warn "Pages returned HTTP $code for ${group}.<pages-domain> (301 = nginx vhost mismatch)" ;;
  esac
}

cmd_verify() {
  CURRENT_PHASE=verify
  local bad
  phase "Verify (SOP phase H)"
  wait_healthy
  info "Background migrations by status: $(gitlab-psql -At -F= -c 'SELECT status, count(*) FROM batched_background_migrations GROUP BY 1 ORDER BY 1;' | paste -sd' ')"
  info "Running gitlab:check (1–2 min)..."
  local out status=pass
  out="$(gitlab-rake gitlab:check SANITIZE=true 2>&1)" || { tail -20 <<<"$out"; die "gitlab:check did not run to completion."; }
  grep -q 'Checking GitLab App ... Finished' <<<"$out" || { tail -20 <<<"$out"; die "gitlab:check output incomplete."; }
  bad="$(grep -E '\.\.\. (no|[Ff]ailed|[Ee]rror)|Try fixing it' <<<"$out" | grep -vE 'orphaned|Reply by email|LDAP' || true)"
  if [[ -z "$bad" ]]; then ok "gitlab:check clean"; else warn "gitlab:check reported:"; info "$bad"; status=warn; fi
  info "Running git fsck on every repository..."
  out="$(gitlab-rake gitlab:git:fsck 2>&1)" || { tail -20 <<<"$out"; die "git fsck did not run to completion."; }
  grep -qx 'Done' <<<"$out" || { tail -20 <<<"$out"; die "git fsck output incomplete."; }
  bad="$(grep -vE 'Performed integrity check|dangling|^Done$' <<<"$out" | grep -iE '^(error|fatal)|missing (blob|tree|commit|tag)|broken link' || true)"
  [[ -z "$bad" ]] || { info "$bad"; die "Repository integrity problems found."; }
  ok "git fsck clean (dangling objects are harmless and ignored)"
  pages_check
  result verify "$status" "$(current_ver)"
}

cmd_runner() {
  CURRENT_PHASE=runner
  local minor have want pkgs
  phase "GitLab Runner (SOP phase I.1)"
  pkg_installed gitlab-runner || { info "gitlab-runner not installed — skipped."; result runner skip; return 0; }
  minor="$(minor_of "$(current_ver)")"
  have="$(dpkg-query -W -f='${Version}' gitlab-runner)"
  want="$(apt-cache madison gitlab-runner | awk -F'|' '{gsub(/ /,"",$2); print $2}' | grep -E "^${minor//./\\.}\." | sort -V | tail -1 || true)"
  if [[ -z "$want" ]]; then warn "No runner release for $minor yet — leaving $have."; result runner skip; return 0; fi
  if [[ "$have" == "$want" ]]; then ok "Runner already $have"
  else
    pkgs=("gitlab-runner=$want")
    pkg_installed gitlab-runner-helper-images && pkgs+=("gitlab-runner-helper-images=$want")
    info "Runner $have → $want (any running CI job will fail and need a retry)"
    DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1 apt-get install -y --allow-change-held-packages "${pkgs[@]}"
  fi
  # verify prints tokens — keep only the status lines.
  gitlab-runner verify 2>&1 | sed -E 's/\x1b\[[0-9;]*m//g' | awk '/is alive|ERROR/ { n="?"; for (i = 1; i <= NF; i++) if ($i ~ /^runner_name=/) n = substr($i, 13); print "   " n ": " (/is alive/ ? "alive" : "ERROR") }'
  if systemctl is-active --quiet gitlab-runner; then ok "gitlab-runner service active"; else warn "gitlab-runner service not active"; fi
  result runner pass "$want"
}

cmd_finish() {
  CURRENT_PHASE=finish
  local p held=()
  phase "Finish (SOP phase J)"
  for p in "$PKG" gitlab-runner gitlab-runner-helper-images; do pkg_installed "$p" && held+=("$p"); done
  apt-mark hold "${held[@]}" >/dev/null && ok "Held: ${held[*]} (a plain 'apt upgrade' can no longer move them)"
  info "Backups now on disk:"
  # shellcheck disable=SC2012
  ls -lh "$BACKUP_DIR" | tail -n +2 | sed 's/^/     /'
  info "Disk: $(df -h / | awk 'NR==2{print $3" used, "$4" free ("$5")"}')"
  result finish pass "$(current_ver)"
  phase "Left for a human"
  info "1. Browser: log in, /help shows $(current_ver), open a project, /admin/background_migrations has 0 failed."
  info "2. Laptop: git clone over SSH from any project you can access."
  info "3. Tell users it is back. Re-open any temporary firewall (keep SSH restricted)."
  info "4. Keep the snapshot a few days, then delete it (it is billed per GB)."
  info "5. Later, on a separate day: OS updates (apt upgrade is now safe), artifact expiry."
}

cmd_prepare() {
  cmd_preflight
  cmd_cleanup
  cmd_backup
  offsite_gate
  snapshot_instructions
}

cmd_resume() {
  cmd_upgrade
  cmd_verify
  cmd_runner
  cmd_finish
}

usage() {
  cat <<USAGE
gitlab-upgrade.sh $KIT_VERSION — gated upgrades for GitLab Linux package installs

Usage: sudo bash gitlab-upgrade.sh <command> [options]

Typical run:
  prepare    preflight → cleanup report → backup → [off-server copy gate] → snapshot how-to
  resume     (after the snapshot reboot) upgrade hops → verify → runner → finish

Single phases:
  status     one-screen health summary
  path       print the upgrade path only
  preflight  read-only checks (SOP D–E)
  cleanup    report reclaimable disk; --apply to remove (asks per item)
  backup     /etc/gitlab copy + gitlab-backup + checksum; prints copy-off instructions
  upgrade    [off-site + snapshot gates] then pinned install of every stop, with migration gates
  verify     gitlab:check, git fsck, Pages
  runner     match gitlab-runner to the server's minor version
  finish     hold packages, summary, human checklist

Options:
  --target V   latest (default) | 19.5 | 19.5.3
  --apply      cleanup actually removes things
  --yes        no prompts (human gates still require GUK_CONFIRM_<GATE>=yes)
  --no-tmux    allow upgrade outside tmux/screen (not recommended)

Exit codes: 0 ok · 1 failed · 2 waiting for a human gate
Environment: GUK_CONFIRM_OFFSITE, GUK_CONFIRM_SNAPSHOT, GUK_FINALIZE, GUK_EXTRA_STOPS,
             GUK_MIGRATION_TIMEOUT_MIN, GUK_DISK_HEADROOM_GB, GUK_STATE_DIR
Log: $STATE_DIR/logs/   Docs: SOP.md, AGENT.md
USAGE
}

parse_args() {
  while (($#)); do
    case "$1" in
      --target)  TARGET="${2:?--target needs a value}"; shift ;;
      --apply)   APPLY=true ;;
      --yes|-y)  ASSUME_YES=true ;;
      --no-tmux) NO_TMUX=true ;;
      -h|--help) usage; exit 0 ;;
      *) die "Unknown option: $1" ;;
    esac
    shift
  done
}

main() {
  local cmd="${1:-help}"; shift || true
  case "$cmd" in help|-h|--help) usage; return 0 ;; esac
  parse_args "$@"
  need_root
  detect_package
  mkdir -p "$STATE_DIR/logs" && chmod 700 "$STATE_DIR"
  exec > >(tee -a "$STATE_DIR/logs/$(date +%Y%m%d-%H%M%S)-${cmd}.log") 2>&1
  # Report unexpected exits once, from the main shell only (not from $(...) helpers).
  trap '(( BASH_SUBSHELL == 0 )) && result "${CURRENT_PHASE:-main}" fail "line $LINENO exited $?"' ERR
  case "$cmd" in
    status|preflight|cleanup|backup|upgrade|verify|runner|finish|prepare|resume) "cmd_$cmd" ;;
    path) upgrade_path ;;
    *) usage; die "Unknown command: $cmd" ;;
  esac
}

# Tests source this file with GUK_SOURCED=1 to reach the pure helpers.
if [[ "${GUK_SOURCED:-0}" != 1 ]]; then main "$@"; fi
