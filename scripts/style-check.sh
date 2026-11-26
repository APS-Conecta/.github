#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# The shared style check (APS-Conecta/gestion-aio#158): an own app's styles keep to Nextcloud's
# variables and components, so the theme reaches every screen. It reads every stylesheet the app
# ships (.css, .scss and Vue <style> blocks) and every Vue <template>, and reports file:line for
#
#   a literal colour (a hex or a colour function) outside a var() fallback;
#   a font size in px;
#   a plain <button> in a template (use NcButton).
#
# It skips vendored, built, test and translation folders, and it never reads scripts or data:
# that is where a colour that is data lives, such as a unidad's or a map category's. Comments are
# not read. It fails when it finds no .css, .scss or .vue file, so a wrong path can't pass on nothing.
#
#   style-check.sh [DIR]        check DIR's tree (default: .); paths are reported as given
#   style-check.sh --self-test  fixture trees that must pass and must fail
set -euo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SELF_DIR/.."

die() { echo "style-check: $*" >&2; exit 1; }

# check_tree DIR — the contract, over one tree. Prints file:line for every offender and returns 1.
check_tree() {
  local dir="$1" files=()
  [ -d "$dir" ] || { echo "style-check: $dir is not a directory" >&2; return 1; }
  mapfile -d '' files < <(find "$dir" -mindepth 1 -type d \( -name node_modules -o -name vendor \
      -o -name dist -o -name build -o -name js \
      -o -name tests -o -name test -o -name __tests__ -o -name e2e \
      -o -name l10n -o -name translationfiles \) -prune \
    -o -type f \( -name '*.css' -o -name '*.scss' -o -name '*.vue' \) -print0 | sort -z)
  if [ "${#files[@]}" -eq 0 ]; then
    echo "style-check: no .css, .scss or .vue file under $dir: nothing was checked" >&2
    return 1
  fi

  # A .css or .scss file is all style. A .vue file is read in its top-level <template> and <style>
  # blocks, whose tags sit at the start of a line; its <script> is not read.
  awk '
    # uncomment(s, opener, closer) — s without its comments; in_comment carries one across lines
    function uncomment(s, opener, closer,   out, i) {
      out = ""
      while (s != "") {
        if (in_comment) {
          if (!(i = index(s, closer))) return out
          s = substr(s, i + length(closer)); in_comment = 0
        } else {
          if (!(i = index(s, opener))) return out s
          out = out substr(s, 1, i - 1) " "; s = substr(s, i + length(opener)); in_comment = 1
        }
      }
      return out
    }
    # unvar(s) — s without its var() calls, so a fallback colour or size is never read
    function unvar(s,   out, i, j, depth, c) {
      out = ""
      while ((i = index(s, "var("))) {
        out = out substr(s, 1, i - 1) " "
        depth = 1
        for (j = i + 4; j <= length(s) && depth > 0; j++) {
          c = substr(s, j, 1)
          if (c == "(") depth++
          else if (c == ")") depth--
        }
        s = substr(s, j)
      }
      return out s
    }
    function report(what) { printf "%s:%d: %s\n", file, FNR, what; bad = 1 }
    function check_style(s,   rest, n) {
      s = uncomment(s, "/*", "*/")
      sub(/(^|[[:space:]])\/\/.*/, "", s)
      s = tolower(unvar(s))
      for (rest = s; match(rest, /#[0-9a-f]+/); rest = substr(rest, RSTART + RLENGTH)) {
        n = RLENGTH - 1
        if ((n == 3 || n == 4 || n == 6 || n == 8) && substr(rest, RSTART + RLENGTH, 1) !~ /[a-z0-9_-]/)
          report("literal colour " substr(rest, RSTART, RLENGTH) ", use a Nextcloud variable")
      }
      for (rest = s; match(rest, /(^|[^a-z0-9_-])(rgba?|hsla?|hwb|lab|lch|oklab|oklch|color)\(/); rest = substr(rest, RSTART + RLENGTH)) {
        n = substr(rest, RSTART, RLENGTH); sub(/^[^a-z]/, "", n)
        report("literal colour " n "), use a Nextcloud variable")
      }
      for (rest = s; match(rest, /font-size[[:space:]]*:[[:space:]]*[0-9.]+px/); rest = substr(rest, RSTART + RLENGTH)) {
        n = substr(rest, RSTART, RLENGTH); sub(/^font-size[[:space:]]*:[[:space:]]*/, "", n)
        report("font size " n ", use rem or a --font-size-* variable")
      }
    }
    function check_template(s,   rest) {
      for (rest = uncomment(s, "<!--", "-->"); match(rest, /<button([[:space:]>\/]|$)/); rest = substr(rest, RSTART + RLENGTH))
        report("plain <button>, use NcButton")
    }
    FNR == 1 {
      file = FILENAME; sub(/^\.\//, "", file)
      vue = file ~ /\.vue$/; section = vue ? "" : "style"; in_comment = 0
    }
    vue && section == "" && /^<template([[:space:]>]|$)/ { section = "template"; in_comment = 0 }
    vue && section == "" && /^<style([[:space:]>]|$)/ { section = "style"; in_comment = 0 }
    section == "style" { check_style($0) }
    section == "template" { check_template($0) }
    vue && /^<\/(template|style)>/ { section = ""; in_comment = 0 }
    END { exit bad }
  ' "${files[@]}"
}

self_test() {
  local failures=0
  work="$(mktemp -d)"
  trap 'rm -rf "$work"' EXIT

  # fixture NAME — a copy of tests/style-fixture, a tree that passes the whole contract
  fixture() {
    cp -r "$ROOT/tests/style-fixture" "$work/$1"
    echo "$work/$1"
  }

  # must_pass NAME DIR [PATH] — checking PATH (default: .) inside DIR must pass
  must_pass() {
    local out
    if ! out="$(cd "$2" && check_tree "${3:-.}" 2>&1)"; then
      echo "self-test: $1 should pass, failed:"; echo "$out"; failures=1
    fi
  }

  # must_fail NAME DIR REPORT [PATH] — checking PATH (default: .) inside DIR must fail with a line
  # starting with REPORT
  must_fail() {
    local out
    if out="$(cd "$2" && check_tree "${4:-.}" 2>&1)"; then
      echo "self-test: $1 should fail, passed"; failures=1
    elif ! awk -v r="$3" 'index($0, r) == 1 { found = 1 } END { exit !found }' <<<"$out"; then
      echo "self-test: $1 failed without reporting '$3':"; echo "$out"; failures=1
    fi
  }

  local d
  d="$(fixture good)"
  must_pass "a var() fallback colour, NcButton, rem and --font-size-* sizes, a colour in a script" "$d"

  d="$(fixture hex-in-style)"
  printf '<template>\n\t<div />\n</template>\n\n<style scoped>\n.a {\n\tcolor: #fff;\n}\n</style>\n' > "$d/src/Hex.vue"
  must_fail "a hex in a <style>" "$d" "src/Hex.vue:7: "

  d="$(fixture rgb-in-scss)"
  printf '.a {\n\tbackground: rgb(0 0 0 / 50%%);\n}\n' > "$d/src/shade.scss"
  must_fail "rgb() in a .scss" "$d" "src/shade.scss:2: "

  d="$(fixture px-font-size)"
  printf '.a {\n\tpadding: 0.5rem;\n\tfont-size: 12px;\n}\n' > "$d/src/small.css"
  must_fail "font-size: 12px" "$d" "src/small.css:3: "

  d="$(fixture plain-button)"
  printf '<template>\n\t<div>\n\t\t<button @click="go">Ir</button>\n\t</div>\n</template>\n' > "$d/src/Plain.vue"
  must_fail "a plain <button>" "$d" "src/Plain.vue:3: "

  d="$work/empty"; mkdir -p "$d/src"; printf 'export const A = 1\n' > "$d/src/main.js"
  must_fail "an empty tree" "$d" "style-check: no .css, .scss or .vue file under ."

  d="$(fixture skipped)"
  local skip
  for skip in node_modules vendor dist build js tests test __tests__ e2e l10n translationfiles; do
    mkdir -p "$d/$skip/deep"
    printf '.a { color: #fff; font-size: 12px; }\n' > "$d/$skip/deep/x.css"
  done
  must_pass "vendored, built, test and translation folders are not read" "$d"

  d="$(fixture path)"
  mkdir -p "$d/legacy"; printf '.a { color: #fff; }\n' > "$d/legacy/old.css"
  must_pass "a path checks only that part of the tree" "$d" src
  must_fail "the whole tree still holds the offender" "$d" "legacy/old.css:1: "

  [ "$failures" -eq 0 ] || die "self-test failed"
  echo "style-check: self-test ok"
}

case "${1:-}" in
  --self-test) self_test ;;
  *) check_tree "${1:-.}" || die "styles fail the contract: use Nextcloud's variables and components" ;;
esac
