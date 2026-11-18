#!/usr/bin/env bash
# Offline end-to-end run of `.forgejo/module-ci.sh release` against tests/fake-forge.py.
#   bash tests/module-ci-release.sh      (tests/run.sh calls it; prints ok/FAIL lines)
# Needs bash, python3, git and curl. Nothing leaves 127.0.0.1: origin and upstream are
# local bare repos (git url.insteadOf), the forge API is the fake server, and curl/git
# are wrappers that log their argv before running the real tools.
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
W=$(mktemp -d) || exit 1
SERVER_PID=""
trap '[ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null; rm -rf "$W"' EXIT

ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; }
check() { local n=$1; shift; if "$@"; then ok "$n"; else bad "$n"; fi; }
not() { ! "$@"; }

unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY no_proxy NO_PROXY
unset GIT_CONFIG_COUNT GIT_DIR GIT_WORK_TREE
REAL_GIT=$(command -v git)
REAL_CURL=$(command -v curl)
TOKEN=example-token-5f3a9c0d
REPOSITORY=example/developer-option-persist
RUN_NUMBER=7
# the tag module-ci.sh makes from the built version (same rules as there)
TAG="$(sed -n 's/^version=//p' "$REPO/module.prop" | head -n1 | tr -d '\r' | sed -E 's/-(fork|ci)[0-9]+$//')-ci$RUN_NUMBER"
TAG="$(printf '%s' "$TAG" | sed -E 's/[^A-Za-z0-9._-]+/-/g; s/-+/-/g; s/^-//; s/-$//')"
case "$TAG" in v*) ;; *) TAG="v$TAG" ;; esac
ZIP_NAME=developer-option-persist-$TAG.zip

# version-manager shims (asdf, pyenv) need the real HOME, which the scenarios replace
mkdir -p "$W/bin" "$W/py"
ln -s "$(python3 -I -c 'import sys; print(sys.executable)')" "$W/py/python3"
export PATH="$W/py:$PATH"
cat > "$W/bin/curl" <<EOF
#!/bin/sh
f=\$(mktemp "\$MCI_LOG/curl.XXXXXX") && printf '%s\n' "\$@" > "\$f"
exec "$REAL_CURL" "\$@"
EOF
cat > "$W/bin/git" <<EOF
#!/bin/sh
f=\$(mktemp "\$MCI_LOG/git.XXXXXX") && printf '%s\n' "\$@" > "\$f"
i=0
while [ "\$i" -lt "\${GIT_CONFIG_COUNT:-0}" ]; do
  eval "k=\\\${GIT_CONFIG_KEY_\$i:-}"
  [ "\$k" = http.extraHeader ] && echo "\$1" >> "\$MCI_LOG/git-env-auth"
  i=\$((i + 1))
done
exec "$REAL_GIT" "\$@"
EOF
chmod 755 "$W/bin/curl" "$W/bin/git"

# scenario NAME CONF_LINES VERSION FAIL - fork main (BASE) and upstream (one new commit)
# from this tree, a build of their merge like the build step makes, then the release
scenario() {
  S="$W/$1"
  RC=99
  mkdir -p "$S/seed" "$S/tmp" "$S/log" "$S/home"
  : > "$S/calls"
  export HOME="$S/home" GIT_CONFIG_GLOBAL="$S/gitconfig" GIT_CONFIG_NOSYSTEM=1
  printf '[user]\n\tname = Example Dev\n\temail = dev@example.invalid\n[init]\n\tdefaultBranch = main\n' > "$GIT_CONFIG_GLOBAL"
  printf '[url "file://%s/upstream.git"]\n\tinsteadOf = https://github.com/nikakvo/developer-option-persist.git\n' "$S" >> "$GIT_CONFIG_GLOBAL"
  (cd "$REPO" && tar -c --exclude=./.git --exclude=./.ci-out .) | tar -x -C "$S/seed"
  [ -n "$2" ] && printf '%s\n' "$2" >> "$S/seed/.forgejo/module-ci.conf"
  if [ -n "$3" ]; then
    awk -v v="$3" '/^version=/ { print "version=" v; next } { print }' "$S/seed/module.prop" > "$S/module.prop"
    cp "$S/module.prop" "$S/seed/module.prop"
  fi
  (
    set -e
    cd "$S/seed"
    "$REAL_GIT" init -q
    "$REAL_GIT" add -A && "$REAL_GIT" commit -q -m "example base"
    "$REAL_GIT" checkout -q -b up
    echo "upstream change" >> CHANGELOG.md
    "$REAL_GIT" commit -q -am "example upstream change"
    "$REAL_GIT" checkout -q main
    echo "fork change" >> LICENSE
    "$REAL_GIT" commit -q -am "example fork change"
    "$REAL_GIT" init -q --bare "$S/origin.git"
    "$REAL_GIT" init -q --bare "$S/upstream.git"
    "$REAL_GIT" push -q "$S/origin.git" main:refs/heads/main
    "$REAL_GIT" push -q "$S/upstream.git" up:refs/heads/main
  ) || { bad "$1: fixture repos"; return 1; }
  BASE=$("$REAL_GIT" -C "$S/seed" rev-parse main)
  # OFF_MAIN=1: dispatch a commit that is in the clone (branch side) but not on main
  RUN_BASE=$BASE
  if [ -n "${OFF_MAIN:-}" ]; then
    "$REAL_GIT" -C "$S/seed" push -q "$S/origin.git" up:refs/heads/side || { bad "$1: side branch"; return 1; }
    RUN_BASE=$("$REAL_GIT" -C "$S/seed" rev-parse up)
  fi

  # what the build step leaves in .ci-out (module-ci.sh build, without the uid switch)
  (
    set -e
    "$REAL_GIT" clone -q "file://$S/origin.git" "$S/src"
    cd "$S/src"
    "$REAL_GIT" checkout -q -B main "$BASE"
    "$REAL_GIT" fetch -q https://github.com/nikakvo/developer-option-persist.git main
    up=$("$REAL_GIT" rev-parse FETCH_HEAD)
    "$REAL_GIT" merge -q --no-ff --no-edit -m "Merge nikakvo/developer-option-persist main ${up:0:12}" "$up"
    mkdir .ci-out
    "$REAL_GIT" bundle create -q .ci-out/merge.bundle "$BASE..main"
    printf '%s\n%s\n' "$("$REAL_GIT" rev-parse HEAD)" "$up" > .ci-out/src
    printf 'nikakvo/developer-option-persist@main %s\n' "${up:0:12}" > .ci-out/desc
    WORK="$S/src" OUT="$S/src/.ci-out"
    pack_paths() {
      python3 -I - "$OUT/module.zip" "$@" <<'PY'
import os, sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w", zipfile.ZIP_DEFLATED) as z:
    for p in sys.argv[2:]:
        for f in ([p] if os.path.isfile(p) else sorted(os.path.join(d, n) for d, _, ns in os.walk(p) for n in ns)):
            if not f.endswith(".gitkeep"):
                z.write(f)
PY
    }
    . .forgejo/module-ci.conf
    build
  ) || { bad "$1: build outputs"; return 1; }
  SRC=$(head -n1 "$S/src/.ci-out/src")

  rm -f "$S/port"
  FAKE_FORGE_FAIL="$4" python3 -I "$REPO/tests/fake-forge.py" "$S/port" "$S/requests" "$S/origin.git" "$REPOSITORY" &
  SERVER_PID=$!
  for _ in $(seq 100); do [ -f "$S/port" ] && break; sleep 0.1; done
  [ -f "$S/port" ] || { bad "$1: fake forge did not start"; return 1; }
  SERVER_URL="http://127.0.0.1:$(cat "$S/port")"
  printf '[url "file://%s/origin.git"]\n\tinsteadOf = %s/%s.git\n' "$S" "$SERVER_URL" "$REPOSITORY" >> "$GIT_CONFIG_GLOBAL"

  (cd "$S" && PATH="$W/bin:$PATH" TMPDIR="$S/tmp" MCI_LOG="$S/log" SERVER_URL="$SERVER_URL" \
    REPOSITORY="$REPOSITORY" BASE_SHA="$RUN_BASE" RELEASE_TOKEN="$TOKEN" RUN_NUMBER="$RUN_NUMBER" \
    bash "$REPO/.forgejo/module-ci.sh" release "$S/src") > "$S/out" 2>&1
  RC=$?
  cp "$S/requests" "$S/requests.release" 2>/dev/null
  "$REAL_CURL" -fsS -o "$S/asset.zip" "$SERVER_URL/$REPOSITORY/releases/download/$TAG/$ZIP_NAME" 2>/dev/null || rm -f "$S/asset.zip"
  kill "$SERVER_PID" 2>/dev/null
  wait "$SERVER_PID" 2>/dev/null
  SERVER_PID=""
  # METHOD PATH auth|anon, one line per request
  python3 -I -c 'import json,sys
for l in open(sys.argv[1]):
    r = json.loads(l); print(r["method"], r["path"], "auth" if r["auth"] else "anon")' "$S/requests.release" > "$S/calls" 2>/dev/null
  return 0
}

zip_prop() { python3 -I -c 'import sys,zipfile; print(zipfile.ZipFile(sys.argv[1]).read("module.prop").decode(), end="")' "$1" 2>/dev/null; }
origin_show() { "$REAL_GIT" --git-dir "$S/origin.git" show "main:$1" 2>/dev/null; }
json_get() { python3 -I -c 'import json,sys; print(json.loads(sys.stdin.read())[sys.argv[1]])' "$1" 2>/dev/null; }
same_file() { cmp -s "$1" "$2" || { diff "$1" "$2" | sed "s/^/     /"; return 1; }; }
no_token_in_argv() { ! grep -rlF -e "$TOKEN" "$S/log" | grep -q .; }
tmp_empty() { [ -z "$(ls -A "$S/tmp")" ]; }
curl_timeouts() {
  local f n=0
  for f in "$S"/log/curl.*; do
    [ "$(grep -x -A1 -e --connect-timeout "$f" | sed -n 2p)" = 30 ] || return 1
    [ "$(grep -x -A1 -e --max-time "$f" | sed -n 2p)" = 600 ] || return 1
    n=$((n + 1))
  done
  [ "$n" -ge 10 ]
}
retry_reads_only() {
  local f m gets=0
  for f in "$S"/log/curl.*; do
    m=$(grep -x -A1 -e -X "$f" | sed -n 2p)
    case "$m" in
      GET) grep -qx -e --retry "$f" || return 1; gets=$((gets + 1)) ;;
      POST|PATCH|DELETE) ! grep -qx -e --retry "$f" || return 1 ;;
    esac
  done
  [ "$gets" -ge "${1:-1}" ]
}
not_published() { ! grep -q '^PATCH ' "$S/calls"; }

conf_offset() { local v; v=$(sed -n 's/^VERSION_CODE_OFFSET=//p' "$REPO/.forgejo/module-ci.conf" | head -n1); echo "${v:-0}"; }
BUILT_VC=$(sed -n 's/^versionCode=//p' "$REPO/module.prop" | head -n1)
VC=$((BUILT_VC + $(conf_offset)))
A=/api/v1/repos/$REPOSITORY

# ---------- normal release ----------

scenario release "" "" ""
check "release: exits 0" [ "$RC" = 0 ]
cat > "$S/want" <<EOF
GET $A/releases/tags/$TAG auth
GET $A/tags/$TAG auth
POST $A/releases auth
POST $A/releases/1/assets?name=$ZIP_NAME auth
GET $A/releases/1/assets/100 auth
GET /$REPOSITORY/releases/download/$TAG/$ZIP_NAME auth
PATCH $A/releases/1 auth
GET $A/tags/$TAG auth
GET /$REPOSITORY/releases/download/$TAG/$ZIP_NAME anon
GET /$REPOSITORY/raw/branch/main/.forgejo/update.json anon
EOF
check "release: forge calls in order (draft, upload, download-verify, publish, tag, anon download, update.json)" same_file "$S/want" "$S/calls"
check "release: merge pushed to main before the update.json commit" [ "$("$REAL_GIT" --git-dir "$S/origin.git" rev-parse main^ 2>/dev/null)" = "$SRC" ]
check "release: update.json commit message" [ "$("$REAL_GIT" --git-dir "$S/origin.git" log -1 --format=%s main 2>/dev/null)" = "update.json: $TAG (versionCode $VC)" ]
check "release: update.json versionCode" [ "$(origin_show .forgejo/update.json | json_get versionCode)" = "$VC" ]
check "release: update.json zipUrl" [ "$(origin_show .forgejo/update.json | json_get zipUrl)" = "$SERVER_URL/$REPOSITORY/releases/download/$TAG/$ZIP_NAME" ]
check "release: published asset carries version" bash -c '[ "$(sed -n "s/^version=//p" <<<"$1")" = "$2" ]' _ "$(zip_prop "$S/asset.zip")" "$TAG"
check "release: published asset carries versionCode" bash -c '[ "$(sed -n "s/^versionCode=//p" <<<"$1")" = "$2" ]' _ "$(zip_prop "$S/asset.zip")" "$VC"
check "release: published asset carries the forge updateJson" bash -c '[ "$(sed -n "s/^updateJson=//p" <<<"$1")" = "$2" ]' _ "$(zip_prop "$S/asset.zip")" "$SERVER_URL/$REPOSITORY/raw/branch/main/.forgejo/update.json"
check "release: root module.prop untouched without SYNC_ROOT_PROP" bash -c '[ "$1" = "$2" ]' _ "$(origin_show module.prop)" "$(cat "$REPO/module.prop")"

check "release: token in no curl or git argv" no_token_in_argv
check "release: git clone and pushes get the token from the environment" bash -c 'grep -qx clone "$1" && [ "$(grep -cx push "$1")" = 2 ]' _ "$S/log/git-env-auth"
check "release: header file removed after success" tmp_empty
check "release: every curl call has --connect-timeout 30 --max-time 600" curl_timeouts
check "release: --retry on GET API calls only, never POST/PATCH/DELETE" retry_reads_only

# ---------- failure after the draft exists ----------

scenario fail-upload "" "" upload
check "upload failure: exits non-zero" [ "$RC" != 0 ]
check "upload failure: the failed upload is not retried" [ "$(grep -c "^POST $A/releases/1/assets" "$S/calls")" = 1 ]
check "upload failure: no --retry on POST/DELETE" retry_reads_only 0
check "upload failure: draft deleted" grep -qx "DELETE $A/releases/1 auth" "$S/calls"
check "upload failure: nothing published" not_published
check "upload failure: token in no curl or git argv" no_token_in_argv
check "upload failure: header file removed" tmp_empty
check "upload failure: main not moved" [ "$("$REAL_GIT" --git-dir "$S/origin.git" rev-parse main 2>/dev/null)" = "$BASE" ]

# ---------- failure of the publish call ----------

scenario fail-publish "" "" publish
check "publish failure: exits non-zero" [ "$RC" != 0 ]
check "publish failure: draft deleted" grep -qx "DELETE $A/releases/1 auth" "$S/calls"
check "publish failure: merge already on main, no update.json commit" [ "$("$REAL_GIT" --git-dir "$S/origin.git" rev-parse main 2>/dev/null)" = "$SRC" ]
check "publish failure: header file removed" tmp_empty

# ---------- fork-owned module.prop kept at the released version ----------

scenario sync "SYNC_ROOT_PROP=module.prop" "" ""
check "SYNC_ROOT_PROP: exits 0" [ "$RC" = 0 ]
check "SYNC_ROOT_PROP: root module.prop version" bash -c '[ "$(sed -n "s/^version=//p" <<<"$1")" = "$2" ]' _ "$(origin_show module.prop)" "$TAG"
check "SYNC_ROOT_PROP: root module.prop versionCode" bash -c '[ "$(sed -n "s/^versionCode=//p" <<<"$1")" = "$2" ]' _ "$(origin_show module.prop)" "$VC"
check "SYNC_ROOT_PROP: root module.prop updateJson" bash -c '[ "$(sed -n "s/^updateJson=//p" <<<"$1")" = "$2" ]' _ "$(origin_show module.prop)" "$SERVER_URL/$REPOSITORY/raw/branch/main/.forgejo/update.json"

scenario sync-odd-version "SYNC_ROOT_PROP=module.prop" "v1.3&x|y (z)" ""
check "SYNC_ROOT_PROP with & | spaces in the version: exits 0" [ "$RC" = 0 ]
check "SYNC_ROOT_PROP with & | spaces in the version: written as text" bash -c '[ "$(sed -n "s/^version=//p" <<<"$1")" = "$2" ]' _ "$(origin_show module.prop)" "v1.3&x|y (z)-ci$RUN_NUMBER"
check "SYNC_ROOT_PROP with & | spaces in the version: updateJson intact" bash -c '[ "$(sed -n "s/^updateJson=//p" <<<"$1")" = "$2" ]' _ "$(origin_show module.prop)" "$SERVER_URL/$REPOSITORY/raw/branch/main/.forgejo/update.json"

# ---------- dispatched commit not on main ----------

OFF_MAIN=1 scenario off-main "" "" ""
check "dispatch of a commit not on main: exits non-zero" [ "$RC" != 0 ]
check "dispatch of a commit not on main: stops before the draft" not grep -q "^POST $A/releases" "$S/calls"
check "dispatch of a commit not on main: says why" grep -q "not in main" "$S/out"

exit 0
