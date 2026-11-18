#!/bin/sh
# tests/run.sh - checks for this repo without any test framework.
#
#   sh tests/run.sh
#
# POSIX sh (bash as sh, dash, busybox ash). The module scripts run for real
# against PATH stubs of the Android tools (settings, getprop, setprop, appops,
# pm, dumpsys) that keep their state in files, a module copy and a data
# directory (DOP_DATA_DIR) in a scratch directory under TMPDIR. Nothing here
# starts the daemon. Checks whose tool is missing (bash, python3) are reported
# as skip. tests/ is not packed into the module zip (.forgejo/module-ci.conf).

REPO=$(cd "$(dirname "$0")/.." && pwd) || exit 1
W=$(mktemp -d "${TMPDIR:-/tmp}/dop-tests.XXXXXX") || exit 1
trap 'rm -rf "$W"' EXIT
trap 'exit 130' INT TERM

PASS=0 FAIL=0 SKIP=0
ok() { PASS=$((PASS + 1)); echo "ok   $1"; }
nok() { FAIL=$((FAIL + 1)); echo "FAIL $1"; }
skip() { SKIP=$((SKIP + 1)); echo "skip $1"; }
check() {
  _name=$1
  shift
  if "$@"; then ok "$_name"; else nok "$_name"; fi
}

if [ -n "${BB_ASH_VERSION:-}" ]; then SHELL_ID="busybox ash $BB_ASH_VERSION"
elif [ -n "${BASH_VERSION:-}" ]; then SHELL_ID="bash $BASH_VERSION (as sh)"
else SHELL_ID="sh ($(readlink -f /bin/sh 2>/dev/null))"; fi
echo "# shell: $SHELL_ID"

# ── Stubs ─────────────────────────────────────────────────────────────────────
B="$W/bin"
mkdir -p "$B"
cat >"$B/settings" <<'EOF'
#!/bin/sh
S="$FAKE/settings"
case "$1" in
  get) if [ -f "$S/$2/$3" ]; then cat "$S/$2/$3"; else echo null; fi ;;
  put) mkdir -p "$S/$2" && printf '%s\n' "$4" >"$S/$2/$3" ;;
  delete) rm -f "$S/$2/$3" ;;
  list)
    for f in "$S/$2"/*; do
      [ -f "$f" ] && printf '%s=%s\n' "${f##*/}" "$(cat "$f")"
    done
    exit 0 ;;
  *) exit 1 ;;
esac
EOF
cat >"$B/getprop" <<'EOF'
#!/bin/sh
P="$FAKE/props"
if [ "$#" -eq 0 ]; then
  for f in "$P"/*; do
    [ -f "$f" ] && printf '[%s]: [%s]\n' "${f##*/}" "$(cat "$f")"
  done
  exit 0
fi
if [ -f "$P/$1" ]; then cat "$P/$1"; else echo; fi
EOF
cat >"$B/setprop" <<'EOF'
#!/bin/sh
mkdir -p "$FAKE/props" && printf '%s\n' "$2" >"$FAKE/props/$1"
EOF
cat >"$B/appops" <<'EOF'
#!/bin/sh
A="$FAKE/appops"
mkdir -p "$A"
case "$1" in
  query-op) for f in "$A"/*; do [ -f "$f" ] && echo "${f##*/}"; done; exit 0 ;;
  set) if [ "$4" = allow ]; then : >"$A/$2"; else rm -f "$A/$2"; fi ;;
  get) if [ -f "$FAKE/pkgs/$2" ]; then echo "MOCK_LOCATION: default"; else echo "Error: No UID for $2"; fi ;;
esac
EOF
cat >"$B/pm" <<'EOF'
#!/bin/sh
case "$1:$2" in
  path:android) echo "package:/system/framework/framework-res.apk" ;;
  path:*) [ -f "$FAKE/pkgs/$2" ] && echo "package:/data/app/$2/base.apk" ;;
esac
exit 0
EOF
printf '#!/bin/sh\nexit 0\n' >"$B/dumpsys"
chmod 755 "$B"/*
PATH="$B:$PATH"
export PATH

# newcase <name> - a fresh module copy, data directory and fake device:
# adb_enabled=0, development_settings_enabled=1, screen_off_timeout=30000.
newcase() {
  C="$W/case/$1"
  M="$C/mod/dev-options-persist"
  FAKE="$C/fake"
  DOP_DATA_DIR="$C/data"
  DOP_EXPORT_DIR="$C/export"
  export FAKE DOP_DATA_DIR DOP_EXPORT_DIR
  mkdir -p "$M/sh" "$FAKE/settings/global" "$FAKE/settings/system" "$FAKE/props" "$FAKE/pkgs"
  for f in service.sh uninstall.sh customize.sh module.prop sh/common.sh; do
    cp "$REPO/$f" "$M/$f"
  done
  echo 0 >"$FAKE/settings/global/adb_enabled"
  echo 1 >"$FAKE/settings/global/development_settings_enabled"
  echo 30000 >"$FAKE/settings/system/screen_off_timeout"
  echo 1 >"$FAKE/props/sys.boot_completed"
}

svc() { sh "$M/service.sh" "$@" 2>&1; }
sget() { sh "$B/settings" get "$1" "$2"; }
has() { grep -qx -- "$2" "$1" 2>/dev/null; }
hasnt() { ! grep -qx -- "$2" "$1" 2>/dev/null; }
outhas() { printf '%s\n' "$OUT" | grep -qx -- "$1"; }

# ── Declared checks ───────────────────────────────────────────────────────────
for f in customize.sh service.sh uninstall.sh sh/common.sh META-INF/com/google/android/update-binary; do
  check "sh -n $f" sh -n "$REPO/$f"
done
check "sh -n tests/run.sh" sh -n "$REPO/tests/run.sh"
if command -v bash >/dev/null 2>&1; then
  check "bash -n .forgejo/module-ci.sh" bash -n "$REPO/.forgejo/module-ci.sh"
  check "bash -n .forgejo/module-ci.conf" bash -n "$REPO/.forgejo/module-ci.conf"
else
  skip "bash -n .forgejo/module-ci.sh (no bash)"
  skip "bash -n .forgejo/module-ci.conf (no bash)"
fi
if command -v python3 >/dev/null 2>&1; then
  for f in update.json .forgejo/update.json; do
    check "json $f" python3 -I -c 'import json,sys; json.load(open(sys.argv[1]))' "$REPO/$f"
  done
  if python3 -I -c 'import yaml' 2>/dev/null; then
    check "yaml .forgejo/workflows/module-release.yml" \
      python3 -I -c 'import yaml,sys; yaml.safe_load(open(sys.argv[1]))' "$REPO/.forgejo/workflows/module-release.yml"
  else
    skip "yaml .forgejo/workflows/module-release.yml (no PyYAML)"
  fi
else
  skip "json update.json .forgejo/update.json (no python3)"
  skip "yaml .forgejo/workflows/module-release.yml (no python3)"
fi

# The zip holds only what build() packs: tests/ must not be one of the paths.
zip_paths_ok() {
  _zp=$(sed -n 's/^[[:space:]]*pack_paths[[:space:]]//p' "$REPO/.forgejo/module-ci.conf")
  [ -n "$_zp" ] || return 1
  for _p in $_zp; do
    case "$_p" in tests | tests/* | . | ./ | '*') return 1 ;; esac
  done
  return 0
}
check "module-ci.conf pack_paths leave out tests/" zip_paths_ok

# ── Module behaviour ──────────────────────────────────────────────────────────
newcase enforce
OUT=$(svc --config adb_enabled 1)
check "--config adb_enabled 1: rc=0 applied=1" eval 'outhas rc=0 && outhas applied=1'
check "--config adb_enabled 1: setting written" test "$(sget global adb_enabled)" = 1
check "--config adb_enabled 1: original captured" has "$DOP_DATA_DIR/original" adb_enabled=0
check "--config adb_enabled 1: key marked managed" has "$DOP_DATA_DIR/managed" adb_enabled
check "--config adb_enabled 1: config line" has "$DOP_DATA_DIR/config" adb_enabled=1
OUT=$(svc --status)
check "--status: rc=0, live value matches" eval 'outhas rc=0 && outhas LIVE_adb_enabled=1 && outhas MATCH_adb_enabled=1'
OUT=$(svc --config adb_enabled skip)
check "--config adb_enabled skip: handed back" eval 'outhas rc=0 && hasnt "$DOP_DATA_DIR/managed" adb_enabled'
check "--config adb_enabled skip: value left as it is" test "$(sget global adb_enabled)" = 1

newcase invalid
OUT=$(svc --config adb_enabled 7)
check "--config adb_enabled 7: rejected" eval 'outhas rc=1 && test ! -f "$DOP_DATA_DIR/config"'
OUT=$(svc --config no_such_key 1)
check "--config no_such_key: rejected" outhas rc=1
OUT=$(svc --import ../config)
check "--import ../config: bad name" eval 'outhas error=bad-name && outhas rc=1'
svc --no-such-command >/dev/null
check "unknown command exits 1" test "$?" = 1

# Two adjacent key names are not one key.
newcase multikey
OUT=$(svc --config "adbinstall adbinput" skip)
check "--config with two key names: rejected" eval 'outhas rc=1 && test ! -f "$DOP_DATA_DIR/config"'
mkdir -p "$DOP_DATA_DIR"
printf 'adbinstall adbinput=skip\nadb_enabled=1\n' >"$DOP_DATA_DIR/config"
_err=$(sh "$M/service.sh" --status 2>&1 >/dev/null)
check "config line with two key names: no command run for it" test -z "$_err"
svc --custom-add system screen_off_timeout 600000 >/dev/null
svc --custom-add system other_timeout 5 >/dev/null
OUT=$(svc --custom-del "c1 c2")
check "--custom-del with two ids: not found" eval 'outhas error=not-found && outhas rc=1'

newcase restore
svc --config adb_enabled 1 >/dev/null
svc --config development_settings_enabled 0 >/dev/null
check "restore setup: values enforced" eval 'test "$(sget global adb_enabled)" = 1 && test "$(sget global development_settings_enabled)" = 0'
OUT=$(svc --restore)
check "--restore: rc=0 restored=2" eval 'outhas rc=0 && outhas restored=2'
check "--restore: adb_enabled back to 0" test "$(sget global adb_enabled)" = 0
check "--restore: Developer Options left visible" test "$(sget global development_settings_enabled)" = 1

# Another live process holds the apply lock: --restore must change nothing
# and leave that lock alone.
newcase restore-busy
svc --config adb_enabled 1 >/dev/null
sleep 30 &
_holder=$!
mkdir -p "$DOP_DATA_DIR/run/locks/apply"
echo "$_holder" >"$DOP_DATA_DIR/run/locks/apply/pid"
OUT=$(svc --restore)
check "--restore with the apply lock busy: rc=1 error=busy" eval 'outhas rc=1 && outhas error=busy'
check "--restore with the apply lock busy: lock left to its owner" has "$DOP_DATA_DIR/run/locks/apply/pid" "$_holder"
check "--restore with the apply lock busy: nothing restored" test "$(sget global adb_enabled)" = 1
kill "$_holder" 2>/dev/null
wait "$_holder" 2>/dev/null

newcase custom
OUT=$(svc --custom-add system screen_off_timeout 600000)
check "--custom-add: rc=0 id=c1" eval 'outhas rc=0 && outhas id=c1'
check "--custom-add: value written" test "$(sget system screen_off_timeout)" = 600000
check "--custom-add: custom file line" has "$DOP_DATA_DIR/custom" "c1 system screen_off_timeout 600000"
check "--custom-add: original captured" has "$DOP_DATA_DIR/original" c1=30000
OUT=$(svc --custom-add system 'bad name' 1)
check "--custom-add bad target: rejected" eval 'outhas error=bad-target && outhas rc=1'
OUT=$(svc --custom-del c1)
check "--custom-del c1: removed, value left" eval 'outhas rc=0 && ! grep -q "^c1 " "$DOP_DATA_DIR/custom" && test "$(sget system screen_off_timeout)" = 600000'

newcase backup
svc --config adb_enabled 1 >/dev/null
OUT=$(svc --export)
_file=$(printf '%s\n' "$OUT" | sed -n 's/^file=//p')
check "--export: file written" eval 'outhas rc=0 && test -n "$_file" && has "$DOP_EXPORT_DIR/$_file" adb_enabled=1'
OUT=$(svc --backups)
check "--backups: lists it" eval 'printf "%s\n" "$OUT" | grep -q "^BACKUP=$_file|"'
svc --config adb_enabled skip >/dev/null
OUT=$(svc --import "$_file")
check "--import: value back in the config" eval 'outhas rc=0 && has "$DOP_DATA_DIR/config" adb_enabled=1'

newcase install
OUT=$(MODPATH="$M" sh -c 'ui_print() { :; }; set_perm() { :; }; set_perm_recursive() { :; }; . "$MODPATH/customize.sh"' 2>&1)
check "customize.sh: default config written" has "$DOP_DATA_DIR/config" adb_enabled=1
check "customize.sh: originals captured" has "$DOP_DATA_DIR/original" adb_enabled=0
check "customize.sh: empty managed list" eval 'test -f "$DOP_DATA_DIR/managed" && test ! -s "$DOP_DATA_DIR/managed"'

newcase uninstall
svc --config adb_enabled 1 >/dev/null
sh "$M/uninstall.sh" >/dev/null 2>&1
_i=0
while [ -d "$DOP_DATA_DIR" ] && [ "$_i" -lt 50 ]; do
  sleep 0.2
  _i=$((_i + 1))
done
check "uninstall.sh: adb_enabled restored" test "$(sget global adb_enabled)" = 0
check "uninstall.sh: data directory removed" test ! -d "$DOP_DATA_DIR"

echo "# $PASS passed, $FAIL failed, $SKIP skipped ($SHELL_ID)"
[ "$FAIL" -eq 0 ]
