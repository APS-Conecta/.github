#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Packs, signs and checks one app release for .github/workflows/app-release.yml.
#
#   pack-app.sh tag DIR TAG        refuse unless TAG is v + DIR/appinfo/info.xml's version
#   pack-app.sh parity DIR         DIR's vendored aps-common copies equal aps-common main
#   pack-app.sh pack ID DIR OUT    OUT/ID.tar.gz, OUT/info.xml and OUT/SHA256SUMS from DIR, after the build
#   pack-app.sh sign OUT PUB       OUT/SHA256SUMS.minisig, proven against PUB
#   pack-app.sh --self-test        hermetic: fixture repos and throwaway keys, no network
#
# pack reads SHIPPED_BUNDLE=1 to accept a committed js/ bundle — the caller's `shipped-bundle`
# input, for the one kind of app that may carry one: upstream unreachable and no build manifest
# (side_menu), so the bundle ships as vendored bytes. A package.json still refuses it: an app
# that can build ships nothing committed.
#
# sign reads the app key from APP_SIGNING_KEY (the .sec file's contents) and its passphrase from
# APP_SIGNING_KEY_PASSWORD ("" for a key made with signify -G -n). APS_COMMON_URL overrides the
# aps-common clone URL.
set -euo pipefail

SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

die() { echo "pack-app: $*" >&2; exit 1; }

# info_field FILE NAME — the text of a top-level element of an info.xml
info_field() {
  python3 -c 'import sys, xml.etree.ElementTree as E; print((E.parse(sys.argv[1]).getroot().findtext(sys.argv[2]) or "").strip())' "$1" "$2"
}

# scratch — a temp dir in $work, removed on exit
scratch() { work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT; }

tag() {
  local dir="$1" ref="$2" version
  [ -f "$dir/appinfo/info.xml" ] || die "$dir/appinfo/info.xml not found"
  version="$(info_field "$dir/appinfo/info.xml" version)"
  [[ "$version" =~ ^[0-9]+(\.[0-9]+)+$ ]] || die "info.xml version '$version' is not dotted numbers"
  [ "$ref" = "v$version" ] || die "tag $ref is not v$version, info.xml's version"
}

# The runtime files: everything but these, unless the app ships a .nextcloudignore, which replaces
# them. Both use rsync rules, anchored at the app root ("/src" never drops vendor/aps/common/src).
DEFAULT_EXCLUDES='+ /.htaccess
- /.*
- /src
- /tests
- /e2e
- /docs
- /screenshots
- /compose*.yaml
- /compose*.yml
- /Dockerfile*
- /AGENTS.md
- /CLAUDE.md
- /CONTEXT.md
- /Makefile
- /package.json
- /package-lock.json
- /composer.json
- /composer.lock
- /*.config.js
- /*.config.mjs
- /*.config.ts
- /phpunit*.xml
- /phpunit*.xml.dist
- /phpstan*
- /psalm.xml
- /appinfo/signature.json'

# pack ID DIR OUT — stage DIR's runtime files as ID/, tar them deterministically, write SHA256SUMS
pack() {
  local id="$1" dir="$2" out="$3" ts rules tracked list
  [ -f "$dir/appinfo/info.xml" ] || die "$dir/appinfo/info.xml not found"
  [ "$(info_field "$dir/appinfo/info.xml" id)" = "$id" ] || die "info.xml's <id> is not $id"
  # The bundle rule and its one exception. The release builds the bundle, so a committed js/ is
  # refused — unless the app ships it (SHIPPED_BUNDLE=1, the workflow's `shipped-bundle` input):
  # the honest state of an app whose upstream is unreachable and whose tarball is the source of
  # truth, so the bundle arrives as vendored bytes. A package.json still refuses it, because a
  # buildable app always builds instead.
  if [ "${SHIPPED_BUNDLE:-0}" = 1 ]; then
    [ ! -f "$dir/package.json" ] \
      || die "shipped-bundle refuses a package.json — the release builds a bundle it can build"
  else
    tracked="$(git -C "$dir" ls-files -- ':(glob)js/*.js' ':(glob)js/*.mjs')"
    [ -z "$tracked" ] || die "the bundle is committed (${tracked//$'\n'/ }); the release builds it — remove it from git"
  fi
  mkdir -p "$out"
  [ -z "$(ls -A "$out")" ] || die "$out is not empty"
  scratch
  rules="$work/rules"
  if [ -f "$dir/.nextcloudignore" ]; then
    ! grep -q '^!' "$dir/.nextcloudignore" \
      || die ".nextcloudignore: '!' lines are not supported (rsync rules; rsync would drop the path silently)"
    cp "$dir/.nextcloudignore" "$rules"
  else
    printf '%s\n' "$DEFAULT_EXCLUDES" > "$rules"
  fi
  rsync -a --filter='- .git' --filter='- node_modules' --exclude-from="$rules" "$dir/" "$work/$id/"
  ts="$(git -C "$dir" log -1 --format=%ct)"
  tar --sort=name --mtime="@$ts" --owner=0 --group=0 --numeric-owner --format=gnu \
    --mode='u+w,go-w,a+rX' -C "$work" -c "$id" | gzip -n > "$work/$id.tar.gz"

  list="$(tar -tzf "$work/$id.tar.gz")"
  ! grep -qv "^$id/" <<<"$list" || die "a member sits outside $id/"
  ! grep -qx "$id/appinfo/signature.json" <<<"$list" \
    || die "appinfo/signature.json is in the tarball; Nextcloud's integrity check would flag the app"
  grep -qE "^$id/js/[^/]+\.m?js$" <<<"$list" || die "no bundle: $id/js/ has no .js or .mjs file after the build"
  tar -xOzf "$work/$id.tar.gz" "$id/appinfo/info.xml" | cmp -s - "$dir/appinfo/info.xml" \
    || die "the tarball's info.xml is not the app's"

  mv "$work/$id.tar.gz" "$out/$id.tar.gz"
  cp "$dir/appinfo/info.xml" "$out/info.xml"
  ( cd "$out" && sha256sum "$id.tar.gz" info.xml > SHA256SUMS )
}

# parity DIR — the aps-common copies DIR vendors (the layout of every app's `make aps-sync`) equal
# aps-common's main; an app that vendors none passes without cloning it
parity() {
  local dir="$1" common bad=0
  if [ ! -e "$dir/vendor/aps/common/src" ] && [ ! -e "$dir/src/aps" ] && [ ! -e "$dir/tests/stubs/OC/Hooks/Emitter.php" ]; then
    echo "pack-app: no vendored aps-common copy"; return 0
  fi
  scratch
  common="$work/aps-common"
  git clone -q --depth 1 "${APS_COMMON_URL:-https://github.com/APS-Conecta/aps-common.git}" "$common" \
    || die "cannot clone aps-common"
  if [ -e "$dir/vendor/aps/common/src" ]; then diff -r "$common/src" "$dir/vendor/aps/common/src" || bad=1; fi
  if [ -e "$dir/src/aps" ]; then diff -r --exclude='*.test.js' "$common/js" "$dir/src/aps" || bad=1; fi
  if [ -e "$dir/tests/stubs/OC/Hooks/Emitter.php" ]; then
    diff "$common/stub/OC/Hooks/Emitter.php" "$dir/tests/stubs/OC/Hooks/Emitter.php" || bad=1
  fi
  [ "$bad" -eq 0 ] || die "vendored aps-common copies differ from aps-common main; run 'make aps-sync' and commit"
}

# sign OUT PUB — sign OUT/SHA256SUMS with the app key, then prove it against PUB (apps.pub)
sign() {
  local out="$1" pub="$2"
  [ -n "${APP_SIGNING_KEY:-}" ] || die "APP_SIGNING_KEY is empty; the caller passes it from its release environment"
  scratch
  ( umask 077 && printf '%s\n' "$APP_SIGNING_KEY" > "$work/apps.sec" )
  printf '%s\n' "${APP_SIGNING_KEY_PASSWORD:-}" \
    | signify -S -s "$work/apps.sec" -m "$out/SHA256SUMS" -x "$out/SHA256SUMS.minisig" \
    || { rm -f "$out/SHA256SUMS.minisig"; die "signing failed: wrong APP_SIGNING_KEY or APP_SIGNING_KEY_PASSWORD"; }
  signify -V -q -p "$pub" -m "$out/SHA256SUMS" -x "$out/SHA256SUMS.minisig" \
    || die "the signature does not verify against $pub; the key is not the app key the installer trusts"
  ( cd "$out" && sha256sum -c --quiet SHA256SUMS ) || die "SHA256SUMS does not match the files beside it"
}

# shellcheck disable=SC2016,SC2034,SC2317  # check's payloads are eval'd single-quoted strings
if [ "${1:-}" = "--self-test" ]; then
  for c in git rsync signify python3; do command -v "$c" >/dev/null || die "self-test: $c missing"; done
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  n=0; failed=0
  check() { n=$((n + 1)); if eval "$2"; then :; else echo "  FAIL: $1" >&2; failed=$((failed + 1)); fi; }
  run() { rc=0; bash "$SELF" "$@" >/dev/null 2>&1 || rc=$?; }

  # mk_app DIR VERSION — a committed fixture app, id demo, laid out like the org's apps
  mk_app() {
    mkdir -p "$1/appinfo" "$1/lib" "$1/src" "$1/tests" "$1/docs" "$1/.github" \
      "$1/vendor/aps/common/src" "$1/templates"
    printf '<?xml version="1.0"?>\n<info>\n  <id>demo</id>\n  <version>%s</version>\n</info>\n' "$2" > "$1/appinfo/info.xml"
    echo '<?php' > "$1/lib/Application.php"
    echo '<?php' > "$1/vendor/aps/common/src/Text.php"
    echo '<?php' > "$1/templates/main.php"
    echo 'main' > "$1/src/main.js"
    echo '<?php' > "$1/tests/AppTest.php"
    echo 'docs' > "$1/docs/index.md"
    echo 'ci' > "$1/.github/ci.yml"
    echo 'Options -Indexes' > "$1/.htaccess"
    echo 'agents' > "$1/AGENTS.md"
    echo 'services:' > "$1/compose.yaml"
    echo '{}' > "$1/package.json"
    printf 'js/\nnode_modules/\n' > "$1/.gitignore"
    ( cd "$1" && git init -q && git add -A \
      && git -c user.email=t@test.invalid -c user.name=t commit -qm fixture )
  }
  # build DIR — what the caller's build step leaves behind: the bundle and node_modules
  build() { mkdir -p "$1/js" "$1/node_modules/dep"; echo 'bundle' > "$1/js/demo-main.mjs"; echo 'dep' > "$1/node_modules/dep/index.js"; }
  members() { tar -tzf "$1/demo.tar.gz" 2>/dev/null; }
  # has OUT PATH... — every PATH is a member under demo/; lacks OUT ERE — no member under demo/ matches
  has() { local list f; list="$(members "$1")"; shift
    for f in "$@"; do grep -qxF "demo/$f" <<<"$list" || return 1; done; }
  lacks() { ! grep -qE "^demo/($2)(/|$)" <<<"$(members "$1")"; }

  mk_app "$tmp/app" 1.2.3
  run tag "$tmp/app" v1.2.3
  check "tag: v + info.xml's version passes" '[ "$rc" -eq 0 ]'
  run tag "$tmp/app" v1.2.4
  check "tag: a tag that differs from info.xml's version is refused" '[ "$rc" -ne 0 ]'
  mk_app "$tmp/fork" 3.1.7-aps1
  run tag "$tmp/fork" v3.1.7-aps1
  check "tag: a non-numeric version is refused (fork versions stay monotonic)" '[ "$rc" -ne 0 ]'

  build "$tmp/app"
  run pack demo "$tmp/app" "$tmp/o1"
  check "pack: the tarball, info.xml and SHA256SUMS" \
    '[ "$rc" -eq 0 ] && [ -f "$tmp/o1/demo.tar.gz" ] && [ -f "$tmp/o1/info.xml" ] && [ -f "$tmp/o1/SHA256SUMS" ]'
  check "pack: every member sits under demo/" \
    '[ -n "$(members "$tmp/o1")" ] && ! grep -qv "^demo/" <<<"$(members "$tmp/o1")"'
  check "pack: info.xml is the app's, byte for byte" 'cmp -s "$tmp/o1/info.xml" "$tmp/app/appinfo/info.xml"'
  check "pack: SHA256SUMS names the tarball and info.xml, and verifies" \
    '[ "$(cut -d" " -f3 "$tmp/o1/SHA256SUMS" | tr "\n" " ")" = "demo.tar.gz info.xml " ] \
      && ( cd "$tmp/o1" && sha256sum -c --quiet SHA256SUMS )'
  check "defaults: runtime files stay — lib, templates, the bundle, .htaccess, vendored aps-common" \
    'has "$tmp/o1" lib/Application.php templates/main.php js/demo-main.mjs .htaccess vendor/aps/common/src/Text.php'
  check "defaults: dev files go — src, tests, docs, dotfiles, agent files, compose, package.json, node_modules" \
    'lacks "$tmp/o1" "src|tests|docs|\.github|\.gitignore|AGENTS\.md|compose\.yaml|package\.json|node_modules"'

  # a second clone of the same commit: other mtimes, another umask — the bytes must not move
  ( umask 077 && git clone -q "$tmp/app" "$tmp/clone" && build "$tmp/clone" \
      && find "$tmp/clone" -exec touch -d '2001-02-03 04:05:06' {} + )
  run pack demo "$tmp/clone" "$tmp/o2"
  check "determinism: another clone of the commit packs the same sha256" \
    '[ "$rc" -eq 0 ] && [ "$(sha256sum < "$tmp/o2/demo.tar.gz")" = "$(sha256sum < "$tmp/o1/demo.tar.gz")" ]'

  printf '/.*\n/docs\n' > "$tmp/clone/.nextcloudignore"
  run pack demo "$tmp/clone" "$tmp/o3"
  check ".nextcloudignore: it replaces the defaults — docs goes, src and tests stay" \
    '[ "$rc" -eq 0 ] && lacks "$tmp/o3" "docs|\.nextcloudignore" && has "$tmp/o3" src/main.js tests/AppTest.php'
  printf '/vendor/*\n!/vendor/aps\n' > "$tmp/clone/.nextcloudignore"
  run pack demo "$tmp/clone" "$tmp/o4"
  check ".nextcloudignore: a '!' line is refused (rsync would drop vendor/aps silently)" \
    '[ "$rc" -ne 0 ] && [ ! -e "$tmp/o4/demo.tar.gz" ]'
  rm "$tmp/clone/.nextcloudignore"

  echo '{}' > "$tmp/clone/appinfo/signature.json"; echo '/.*' > "$tmp/clone/.nextcloudignore"
  run pack demo "$tmp/clone" "$tmp/o5"
  check "refused: appinfo/signature.json in the tarball (Nextcloud's integrity check would flag the app)" '[ "$rc" -ne 0 ]'
  rm "$tmp/clone/appinfo/signature.json" "$tmp/clone/.nextcloudignore"
  run pack other "$tmp/clone" "$tmp/o6"
  check "refused: an app id that is not info.xml's <id>" '[ "$rc" -ne 0 ]'
  git clone -q "$tmp/app" "$tmp/unbuilt"
  run pack demo "$tmp/unbuilt" "$tmp/o7"
  check "refused: no bundle (js/*.js or js/*.mjs) — the build made nothing" '[ "$rc" -ne 0 ]'
  build "$tmp/unbuilt"
  ( cd "$tmp/unbuilt" && git add -f js/demo-main.mjs && git -c user.email=t@test.invalid -c user.name=t commit -qm bundle )
  run pack demo "$tmp/unbuilt" "$tmp/o8"
  check "refused: a committed bundle — the release builds it" '[ "$rc" -ne 0 ]'

  # shipped-bundle — the caller's declaration that the bundle ships as vendored bytes: an app
  # cloned from a source nobody can reach (side_menu), with no build manifest of its own. The
  # committed bundle packs and ships; a package.json still refuses it, because a buildable app
  # builds instead of shipping.
  git clone -q "$tmp/app" "$tmp/shipped"
  build "$tmp/shipped"
  ( cd "$tmp/shipped" && git rm -q package.json && git add -f js/demo-main.mjs \
      && git -c user.email=t@test.invalid -c user.name=t commit -qm "a bundle that ships as vendored bytes" )
  shipped() { rc=0; SHIPPED_BUNDLE=1 bash "$SELF" pack demo "$1" "$2" >/dev/null 2>&1 || rc=$?; }
  shipped "$tmp/shipped" "$tmp/o9"
  check "shipped-bundle: a committed bundle with no build packs, and it ships" \
    '[ "$rc" -eq 0 ] && [ -f "$tmp/o9/demo.tar.gz" ] && has "$tmp/o9" js/demo-main.mjs'
  shipped "$tmp/app" "$tmp/o10"
  check "shipped-bundle: a package.json refuses it — a buildable app never ships its bundle committed" \
    '[ "$rc" -ne 0 ] && [ ! -e "$tmp/o10/demo.tar.gz" ]'

  mk_app "$tmp/php-only" 1.2.3
  ( cd "$tmp/php-only" && git rm -q package.json \
      && git -c user.email=t@test.invalid -c user.name=t commit -qm "server app without a frontend" )
  php_pack() { rc=0; PHP_ONLY=1 bash "$SELF" pack demo "$1" "$2" >/dev/null 2>&1 || rc=$?; }
  php_pack "$tmp/php-only" "$tmp/php-runtime"
  check "PHP-only: runtime classes pack without a JavaScript bundle" \
    '[ "$rc" -eq 0 ] && has "$tmp/php-runtime" lib/Application.php appinfo/info.xml && lacks "$tmp/php-runtime" "src|tests|package.json"'
  php_pack "$tmp/app" "$tmp/php-with-manifest"
  check "PHP-only: a frontend build manifest refuses the exemption" '[ "$rc" -ne 0 ]'
  mkdir -p "$tmp/php-only/js"; echo 'runtime' > "$tmp/php-only/js/demo.js"
  php_pack "$tmp/php-only" "$tmp/php-with-js"
  check "PHP-only: browser JavaScript refuses the exemption" '[ "$rc" -ne 0 ]'
  rm -rf "$tmp/php-only/js" "$tmp/php-only/lib"
  php_pack "$tmp/php-only" "$tmp/php-empty"
  check "PHP-only: a missing runtime class refuses publication" '[ "$rc" -ne 0 ]'

  # throwaway keys: a passphrase-less one, an encrypted one, and an unrelated public key
  ( umask 077 && signify -G -n -p "$tmp/plain.pub" -s "$tmp/plain.sec" -c test \
      && printf 'pw\npw\n' | signify -G -p "$tmp/enc.pub" -s "$tmp/enc.sec" -c test >/dev/null \
      && signify -G -n -p "$tmp/other.pub" -s "$tmp/other.sec" -c test )
  # sign_as N SECFILE PASSWORD PUB — sign a fresh copy of o1 as s<N>
  sign_as() { cp -r "$tmp/o1" "$tmp/s$1"
    rc=0; APP_SIGNING_KEY="$(cat "$2")" APP_SIGNING_KEY_PASSWORD="$3" bash "$SELF" sign "$tmp/s$1" "$4" >/dev/null 2>&1 || rc=$?; }
  proven() { ( cd "$tmp/s$1" && signify -V -q -p "$2" -m SHA256SUMS -x SHA256SUMS.minisig ); }
  sign_as 1 "$tmp/plain.sec" "" "$tmp/plain.pub"
  check "sign: a passphrase-less key signs SHA256SUMS and the signature verifies" '[ "$rc" -eq 0 ] && proven 1 "$tmp/plain.pub"'
  sign_as 2 "$tmp/enc.sec" pw "$tmp/enc.pub"
  check "sign: an encrypted key signs with its passphrase on stdin" '[ "$rc" -eq 0 ] && proven 2 "$tmp/enc.pub"'
  sign_as 3 "$tmp/enc.sec" wrong "$tmp/enc.pub"
  check "sign: a wrong passphrase fails and leaves no signature" '[ "$rc" -ne 0 ] && [ ! -e "$tmp/s3/SHA256SUMS.minisig" ]'
  sign_as 4 /dev/null "" "$tmp/plain.pub"
  check "sign: an empty key fails (the caller did not pass the secret)" '[ "$rc" -ne 0 ]'
  sign_as 5 "$tmp/plain.sec" "" "$tmp/other.pub"
  check "sign: the proof fails against a public key that is not the signer's" '[ "$rc" -ne 0 ]'

  # an aps-common fixture repo, and an app vendoring all three copies the way `make aps-sync` lays them out
  mkdir -p "$tmp/common/src" "$tmp/common/js" "$tmp/common/stub/OC/Hooks"
  echo '<?php' > "$tmp/common/src/Text.php"
  echo 'api' > "$tmp/common/js/api.js"
  echo 'test' > "$tmp/common/js/api.test.js"
  echo '<?php // stub' > "$tmp/common/stub/OC/Hooks/Emitter.php"
  ( cd "$tmp/common" && git init -q && git add -A && git -c user.email=t@test.invalid -c user.name=t commit -qm common )
  mkdir -p "$tmp/clone/src/aps" "$tmp/clone/tests/stubs/OC/Hooks"
  echo 'api' > "$tmp/clone/src/aps/api.js"
  echo '<?php // stub' > "$tmp/clone/tests/stubs/OC/Hooks/Emitter.php"
  parity_of() { rc=0; APS_COMMON_URL="$2" bash "$SELF" parity "$1" >/dev/null 2>&1 || rc=$?; }
  parity_of "$tmp/clone" "$tmp/common"
  check "parity: vendored copies equal to aps-common pass" '[ "$rc" -eq 0 ]'
  echo '<?php // drift' > "$tmp/clone/vendor/aps/common/src/Text.php"
  parity_of "$tmp/clone" "$tmp/common"
  check "parity: a vendored PHP copy that differs from aps-common fails" '[ "$rc" -ne 0 ]'
  echo '<?php' > "$tmp/clone/vendor/aps/common/src/Text.php"; echo 'drift' > "$tmp/clone/src/aps/api.js"
  parity_of "$tmp/clone" "$tmp/common"
  check "parity: a vendored JS copy that differs from aps-common fails" '[ "$rc" -ne 0 ]'
  parity_of "$tmp/unbuilt/lib" "$tmp/no-such-repo"
  check "parity: an app with no vendored copy passes without cloning aps-common" '[ "$rc" -eq 0 ]'

  echo "self-test: $n checks, $failed failed"
  [ "$failed" -eq 0 ]
  exit
fi

case "${1:-}" in
  tag) [ $# -eq 3 ] || die "usage: pack-app.sh tag DIR TAG"; tag "$2" "$3" ;;
  pack) [ $# -eq 4 ] || die "usage: pack-app.sh pack ID DIR OUT"; pack "$2" "$3" "$4" ;;
  sign) [ $# -eq 3 ] || die "usage: pack-app.sh sign OUT PUB"; sign "$2" "$3" ;;
  parity) [ $# -eq 2 ] || die "usage: pack-app.sh parity DIR"; parity "$2" ;;
  *) die "usage: pack-app.sh tag DIR TAG | pack ID DIR OUT | sign OUT PUB | parity DIR | --self-test" ;;
esac
