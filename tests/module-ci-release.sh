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

  # what the build step leaves in .ci-out (module-ci.sh build, without the uid switch).
  # GIT_ALLOW_PROTOCOL=file here and in the release run: a URL no insteadOf maps fails
  # instead of reaching the network
  (
    set -e
    export GIT_ALLOW_PROTOCOL=file
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

  (cd "$S" && GIT_ALLOW_PROTOCOL=file PATH="$W/bin:$PATH" TMPDIR="$S/tmp" MCI_LOG="$S/log" SERVER_URL="$SERVER_URL" \
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
FLOOR=$(sed -n 's/^VERSION_CODE_FLOOR=//p' "$REPO/.forgejo/module-ci.conf" | head -n1)

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
# the fork releases above the upstream build it replaces (VERSION_CODE_OFFSET=2, VERSION_CODE_FLOOR=13)
check "release: zip versionCode is module.prop's + 2 ($((BUILT_VC + 2)))" bash -c '[ "$(sed -n "s/^versionCode=//p" <<<"$1")" = "$2" ]' _ "$(zip_prop "$S/asset.zip")" "$((BUILT_VC + 2))"
check "release: update.json versionCode is module.prop's + 2 ($((BUILT_VC + 2)))" [ "$(origin_show .forgejo/update.json | json_get versionCode)" = "$((BUILT_VC + 2))" ]
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

# ---------- versionCode floor ----------

scenario below-floor "VERSION_CODE_OFFSET=0" "" ""
check "versionCode $BUILT_VC again: exits non-zero" [ "$RC" != 0 ]
check "versionCode $BUILT_VC again: stops before the draft" not grep -q "^POST $A/releases" "$S/calls"
check "versionCode $BUILT_VC again: says why" grep -q "versionCode $BUILT_VC is below the floor $FLOOR" "$S/out"

# ---------- dispatched commit not on main ----------

OFF_MAIN=1 scenario off-main "" "" ""
check "dispatch of a commit not on main: exits non-zero" [ "$RC" != 0 ]
check "dispatch of a commit not on main: stops before the draft" not grep -q "^POST $A/releases" "$S/calls"
check "dispatch of a commit not on main: says why" grep -q "not in main" "$S/out"

# ---------- stalled upstream fetch ----------
# The upstream is a 127.0.0.1 listener that accepts and never answers. module-ci.sh supplies
# the low-speed limit; this run shortens only the time (no limit set here or in git config),
# so the build step's fetch must fail on its own instead of hanging until the job timeout.
# setpriv is a stub that refuses: should the build ever get past the fetch, its uid switch
# and its `kill -9 -1` as the build user never run on this machine.

S="$W/stall"
mkdir -p "$S/src" "$S/home" "$S/bin"
printf '#!/bin/sh\necho "setpriv stub: refused" >&2\nexit 1\n' > "$S/bin/setpriv"
chmod 755 "$S/bin/setpriv"
export HOME="$S/home" GIT_CONFIG_GLOBAL="$S/gitconfig" GIT_CONFIG_NOSYSTEM=1
printf '[user]\n\tname = Example Dev\n\temail = dev@example.invalid\n[init]\n\tdefaultBranch = main\n' > "$GIT_CONFIG_GLOBAL"
python3 -I -c 'import os, socket, sys
s = socket.socket(); s.bind(("127.0.0.1", 0)); s.listen(8)
open(sys.argv[1] + ".tmp", "w").write(str(s.getsockname()[1])); os.rename(sys.argv[1] + ".tmp", sys.argv[1])
held = []
while True: held.append(s.accept()[0])' "$S/port" &
SERVER_PID=$!
for _ in $(seq 100); do [ -f "$S/port" ] && break; sleep 0.1; done
(
  set -e
  cd "$S/src"
  "$REAL_GIT" init -q
  mkdir .forgejo
  printf 'UPSTREAM_URL=http://127.0.0.1:%s/upstream.git\nUPSTREAM_BRANCH=main\nbuild() { :; }\n' "$(cat "$S/port")" > .forgejo/module-ci.conf
  "$REAL_GIT" add -A && "$REAL_GIT" commit -q -m "example base"
) || bad "stall: fixture repo"
start=$SECONDS
(cd "$S" && PATH="$S/bin:$PATH" env -u GIT_HTTP_LOW_SPEED_LIMIT GIT_HTTP_LOW_SPEED_TIME=3 SERVER_URL=http://127.0.0.1:1 \
  REPOSITORY="$REPOSITORY" BASE_SHA="$("$REAL_GIT" -C "$S/src" rev-parse HEAD)" \
  timeout 30 bash "$REPO/.forgejo/module-ci.sh" build "$S/src") > "$S/out" 2>&1
RC=$? took=$((SECONDS - start))
kill "$SERVER_PID" 2>/dev/null; wait "$SERVER_PID" 2>/dev/null; SERVER_PID=""
check "stalled upstream fetch: build fails on its own, not by the 30 s timeout (rc $RC, ${took}s)" bash -c '[ "$1" != 0 ] && [ "$1" != 124 ] && [ "$2" -lt 20 ]' _ "$RC" "$took"
check "stalled upstream fetch: git reports the low-speed abort" grep -q "Operation too slow" "$S/out"

# ---------- build step: what the unprivileged build gets ----------
# module-ci.sh build past the fetch (no upstream). setpriv is an allow-list stub: it records the
# environment and argv of the build-user call and runs only that call, as the current user; every
# other call (the uid switch's `kill -9 -1`) is recorded and never run. env logs its argv; chown
# does nothing (any test uid). The caller exports names the script uses itself (WORK, OUT,
# BUILD_UID), a variable that must not reach the build, a signing secret that must, and entries
# bash cannot un-export.

S="$W/build"
mkdir -p "$S/src" "$S/bin" "$S/home"
export HOME="$S/home" GIT_CONFIG_GLOBAL="$S/gitconfig" GIT_CONFIG_NOSYSTEM=1
printf '[user]\n\tname = Example Dev\n\temail = dev@example.invalid\n[init]\n\tdefaultBranch = main\n' > "$GIT_CONFIG_GLOBAL"
cat > "$S/bin/setpriv" <<EOF
#!/bin/sh
while [ \$# -gt 0 ]; do case "\$1" in --*) shift ;; *) break ;; esac; done
if [ "\$1" = bash ] && [ "\$3" = build-user ]; then
  tr '\\0' '\\n' < /proc/\$\$/environ > "$S/build-env"
  printf '%s\\n' "\$@" > "$S/setpriv-argv"
  exec "\$@"
fi
printf '%s\\n' "\$*" >> "$S/setpriv-refused"
exit 0
EOF
# python, not sh: a shell would add PWD and SHLVL to the environment it passes on
cat > "$S/bin/env" <<EOF
#!$W/py/python3 -I
import os, sys
open("$S/env-argv", "a").write("".join(a + "\n" for a in sys.argv[1:]))
os.execv("$(command -v env)", ["env"] + sys.argv[1:])
EOF
printf '#!/bin/sh\nexit 0\n' > "$S/bin/chown"
chmod 755 "$S/bin/setpriv" "$S/bin/env" "$S/bin/chown"
(
  set -e
  cd "$S/src"
  "$REAL_GIT" init -q
  mkdir .forgejo
  cp "$REPO/.forgejo/module-ci.sh" .forgejo/
  printf 'build() { export -p > "$OUT/build-user-env"; : > "$OUT/module.zip"; }\n' > .forgejo/module-ci.conf
  "$REAL_GIT" add -A && "$REAL_GIT" commit -q -m "example base"
) || bad "build: fixture repo"
SECRET=example-sign-secret-7c1d
(cd "$S" && env 'example.name=1' 'BASH_FUNC_example_fn%%=() {  :
}' SHELLOPTS=braceexpand:hashall:interactive-comments \
  WORK=/nonexistent/example-work OUT=/nonexistent/example-out BUILD_UID=1000 EXAMPLE_CALLER_VAR=1 \
  SIGN_KEY_PASSWORD="$SECRET" GIT_HTTP_LOW_SPEED_TIME=7 PATH="$S/bin:$PATH" SERVER_URL=http://127.0.0.1:1 \
  REPOSITORY="$REPOSITORY" BASE_SHA="$("$REAL_GIT" -C "$S/src" rev-parse HEAD)" \
  timeout 60 bash "$REPO/.forgejo/module-ci.sh" build "$S/src") > "$S/out" 2>&1
RC=$?
want="ANDROID_HOME ANDROID_SDK_ROOT BASE_SHA GIT_HTTP_LOW_SPEED_LIMIT GIT_HTTP_LOW_SPEED_TIME GRADLE_USER_HOME HOME JAVA_HOME JAVA_HOME_21 JAVA_HOME_26 LANG OUT PATH REPOSITORY SERVER_URL SIGN_KEYSTORE_B64 SIGN_KEY_ALIAS SIGN_KEY_PASSWORD SIGN_STORE_PASSWORD "
check "build step: exits 0 when the caller exports WORK, OUT and BUILD_UID" [ "$RC" = 0 ]
check "build step: zip left in the work tree's .ci-out" [ -f "$S/src/.ci-out/module.zip" ]
check "build step: build user gets exactly the listed variables" bash -c '[ "$(cut -d= -f1 "$1" 2>/dev/null | LC_ALL=C sort | tr "\n" " ")" = "$2" ]' _ "$S/build-env" "$want"
check "build step: signing secret reaches the build user" grep -qxF "SIGN_KEY_PASSWORD=$SECRET" "$S/build-env"
check "build step: signing secret in no env or setpriv argv" bash -c '[ -s "$1" ] && [ -s "$2" ] && ! grep -qF -e "$3" "$1" "$2"' _ "$S/env-argv" "$S/setpriv-argv" "$SECRET"
check "build step: build() keeps the caller's git low-speed time, gets the default limit" bash -c 'grep -qx "declare -x GIT_HTTP_LOW_SPEED_TIME=\"7\"" "$1" && grep -qx "declare -x GIT_HTTP_LOW_SPEED_LIMIT=\"1024\"" "$1"' _ "$S/src/.ci-out/build-user-env"
check "build step: the build user's kill -9 -1 reached only the recording stub" grep -qx "kill -9 -1" "$S/setpriv-refused"

exit 0
