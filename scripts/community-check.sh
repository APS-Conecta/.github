#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Checks the org's community files against docs-SSOT T06, as amended by K2 and K3
# (APS-Conecta/instalador#71), so the budgets stay enforced in CI instead of by hand:
#
#   profile/README.md                at most 3 lines
#   CONTRIBUTING.md                  exactly 1 line
#   SECURITY.md                      at most 6 lines
#   .github/PULL_REQUEST_TEMPLATE.md at most 10 lines
#   none of the four contains (case-insensitive): privad, private, aprobaci,
#     approval, hackerone, apsconecta.cl
#   every .github/ISSUE_TEMPLATE/*.yml or *.yaml carries a top-level `type:` of
#     Bug or Task, and both types are present; config.yml/config.yaml is GitHub's
#     chooser, not a form, and is not checked
#
# A "line" is a physical line, blank or not; the whole file counts.
#
#   community-check.sh [DIR]        check DIR's tree (default: this repository)
#   community-check.sh --self-test  fixture trees that must fail, then the live check
set -euo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SELF_DIR/.."

fail() { echo "community-check: $*" >&2; bad=1; }
die() { echo "community-check: $*" >&2; exit 1; }

lines() { awk 'END { print NR }' "$1"; }

# check_tree DIR — the contract, over one tree. Sets bad=1 and reports every violation.
check_tree() {
  local dir="$1" bad=0 f n t types="" present=()
  local -A budget=([profile/README.md]=3 [CONTRIBUTING.md]=1 [SECURITY.md]=6 [.github/PULL_REQUEST_TEMPLATE.md]=10)

  for f in "${!budget[@]}"; do
    if [ ! -f "$dir/$f" ]; then
      fail "$f is missing"
      continue
    fi
    present+=("$dir/$f")
    n="$(lines "$dir/$f")"
    if [ "$f" = CONTRIBUTING.md ]; then
      [ "$n" -eq "${budget[$f]}" ] || fail "$f is $n lines, exactly ${budget[$f]} required"
    else
      [ "$n" -le "${budget[$f]}" ] || fail "$f is $n lines, at most ${budget[$f]}"
    fi
  done

  if [ "${#present[@]}" -gt 0 ] && grep -riEn 'privad|private|aprobaci|approval|hackerone|apsconecta\.cl' "${present[@]}"; then
    fail "a banned word is in a community file (see matches above)"
  fi

  local base
  for f in "$dir"/.github/ISSUE_TEMPLATE/*.yml "$dir"/.github/ISSUE_TEMPLATE/*.yaml; do
    [ -f "$f" ] || continue
    base="$(basename "$f")"
    [ "$base" = config.yml ] || [ "$base" = config.yaml ] && continue   # the chooser, not a form
    t="$(grep -E '^type:[[:space:]]*(Bug|Task)[[:space:]]*$' "$f" | head -1 | sed 's/^type:[[:space:]]*//;s/[[:space:]]*$//' || true)"
    if [ -z "$t" ]; then
      fail "$base carries no top-level type: Bug or Task"
    else
      types="$types $t"
    fi
  done
  [[ "$types" == *Bug* ]] || fail "no issue form carries type: Bug"
  [[ "$types" == *Task* ]] || fail "no issue form carries type: Task"

  return "$bad"
}

self_test() {
  local failures=0
  work="$(mktemp -d)"
  trap 'rm -rf "$work"' EXIT

  # fixture NAME — a tree that passes the whole contract
  fixture() {
    local d="$work/$1"
    mkdir -p "$d/.github/ISSUE_TEMPLATE" "$d/profile"
    cp "$ROOT/profile/README.md" "$d/profile/README.md"
    cp "$ROOT/CONTRIBUTING.md" "$d/CONTRIBUTING.md"
    cp "$ROOT/SECURITY.md" "$d/SECURITY.md"
    cp "$ROOT/.github/PULL_REQUEST_TEMPLATE.md" "$d/.github/PULL_REQUEST_TEMPLATE.md"
    cp "$ROOT/.github/ISSUE_TEMPLATE/error.yml" "$d/.github/ISSUE_TEMPLATE/error.yml"
    cp "$ROOT/.github/ISSUE_TEMPLATE/tarea.yml" "$d/.github/ISSUE_TEMPLATE/tarea.yml"
    echo "$d"
  }

  # must_pass NAME DIR — the fixture must pass
  must_pass() {
    if ! check_tree "$2" 2>"$work/pass.err"; then
      echo "self-test: $1 should pass, failed:"; cat "$work/pass.err"; failures=1
    fi
  }

  # must_fail NAME DIR PATTERN — the fixture must fail naming PATTERN
  must_fail() {
    local out
    if out="$(check_tree "$2" 2>&1)"; then
      echo "self-test: $1 should fail, passed"; failures=1
    elif ! grep -q "$3" <<<"$out"; then
      echo "self-test: $1 failed without naming '$3':"; echo "$out"; failures=1
    fi
  }

  local d
  d="$(fixture good)"
  must_pass "a tree that meets the contract" "$d"

  d="$(fixture profile-long)"; printf 'línea de más\n' >> "$d/profile/README.md"
  must_fail "profile/README.md over budget" "$d" "profile/README.md is 4 lines"

  d="$(fixture contributing-long)"; printf 'línea de más\n' >> "$d/CONTRIBUTING.md"
  must_fail "CONTRIBUTING.md not one line" "$d" "CONTRIBUTING.md is 2 lines"

  d="$(fixture contributing-empty)"; : > "$d/CONTRIBUTING.md"
  must_fail "CONTRIBUTING.md empty" "$d" "CONTRIBUTING.md is 0 lines"

  d="$(fixture security-long)"; printf 'línea de más\notra línea\n' >> "$d/SECURITY.md"
  must_fail "SECURITY.md over budget" "$d" "SECURITY.md is 7 lines"

  d="$(fixture pr-long)"; for i in 1 2 3 4 5 6 7; do printf -- '- [ ] checkbox %s\n' "$i" >> "$d/.github/PULL_REQUEST_TEMPLATE.md"; done
  must_fail "PR template over budget" "$d" "PULL_REQUEST_TEMPLATE.md is 11 lines"

  d="$(fixture no-security)"; rm "$d/SECURITY.md"
  must_fail "SECURITY.md missing" "$d" "SECURITY.md is missing"

  d="$(fixture no-security-banned)"
  rm "$d/SECURITY.md"; printf 'a line with private inside\n' >> "$d/CONTRIBUTING.md"
  must_fail "banned word still reported beside a missing file" "$d" "banned word"

  local word
  for word in privad private aprobaci approval hackerone apsconecta.cl; do
    d="$(fixture "word-$word")"
    printf 'una línea con %s dentro\n' "$word" >> "$d/SECURITY.md"
    must_fail "banned word «$word»" "$d" "banned word"
  done

  d="$(fixture form-untyped)"
  sed -i '/^type:/d' "$d/.github/ISSUE_TEMPLATE/error.yml"
  must_fail "form without a type" "$d" "error.yml carries no top-level"

  d="$(fixture form-foreign-type)"
  sed -i 's/^type: Bug$/type: Feature/' "$d/.github/ISSUE_TEMPLATE/error.yml"
  must_fail "form with a foreign type" "$d" "error.yml carries no top-level"

  d="$(fixture no-task)"; rm "$d/.github/ISSUE_TEMPLATE/tarea.yml"
  must_fail "no form carries type: Task" "$d" "no issue form carries type: Task"

  d="$(fixture form-yaml-untyped)"
  rm "$d/.github/ISSUE_TEMPLATE/error.yml"
  printf 'name: Funcionalidad\ndescription: Algo nuevo.\nbody:\n  - type: textarea\n' > "$d/.github/ISSUE_TEMPLATE/feature.yaml"
  must_fail "an untyped .yaml form does not escape" "$d" "feature.yaml carries no top-level"

  d="$(fixture form-yaml-typed)"
  mv "$d/.github/ISSUE_TEMPLATE/error.yml" "$d/.github/ISSUE_TEMPLATE/error.yaml"
  must_pass "a typed .yaml form counts as a form" "$d"

  d="$(fixture with-chooser)"
  printf 'blank_issues_enabled: false\n' > "$d/.github/ISSUE_TEMPLATE/config.yml"
  must_pass "config.yml, the chooser, is not a form" "$d"

  [ "$failures" -eq 0 ] || die "self-test failed"
  echo "community-check: self-test ok"

  check_tree "$ROOT" || die "this repository's own community files fail the contract"
  echo "community-check: repository ok"
}

case "${1:-}" in
  --self-test) self_test ;;
  *) check_tree "${1:-$ROOT}" || die "community files fail the contract" ;;
esac
