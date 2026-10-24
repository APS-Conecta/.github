<!-- SPDX-FileCopyrightText: 2026 APS Conecta -->
<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->

# The fork-rebase runbook

How an APS-Conecta fork app takes a new upstream: **rebase**, one local feature per commit,
then verify with the repo's own gates. Written from the IntraVox rebase (instalador #35 —
47 local commits onto a pre-rewrite upstream, eight conflict seams resolved by hand);
eurooffice and desktop_workspace follow the same road.

A rebase rewrites the fork's `main`. Do it on a branch, keep a backup ref, and diff the
result against it before anything is pushed — the old tags (the bake's pins) stay where
they are and keep pointing at the old line; nothing deletes them.

## 0. Before you start

- Add the upstream remote and fetch: `git remote add upstream <url> && git fetch upstream --tags`.
- `git branch backup/pre-rebase main` — the diff against this ref is the whole safety net.
- Know which files are **generated** in this repo (bundles, ratchet baselines, l10n
  manifests): they regenerate, and conflicts inside them are resolved by policy, never by hand.

## 1. The pre-rewrite twin

An upstream that was **published from a rewritten history** (check: the same commit
message appears on both sides under different SHAs, e.g. a `temp:` commit on each) carries
duplicates of commits the fork already has. Replaying them conflicts everywhere. The first
time `git rebase upstream/main` stops on a commit whose message exists upstream under
another SHA: `git rebase --skip` — its content is upstream's, not the fork's.

## 2. Per-path merge policy

Resolve by path, not commit by commit:

| Path | Policy | Why |
|---|---|---|
| build bundles (`js/**`) | take the replayed (local) side; add a `merge=theirs` driver in `$GIT_DIR/info/attributes` and remove it after | bundles are build output; the fork's side carries the local features |
| version fields (`info.xml`, `package.json`, `openapi.json`) | take the local side during replay | the fork's version line wins; the release commit sets the final one |
| ratchet baselines (file budgets, phpstan baseline) | take the local side, then **regenerate at the end** | intermediate numbers are meaningless; the final tree owns the truth |
| l10n source manifests | take the local side, then **regenerate at the end** | same |
| everything else | read the conflict; merge both sides by hand | these are the seams the rebase exists to surface |

Two whole-file policies that keep working: the fork's **deleted-by-decision** files
(docs a fork decision retired) stay deleted — `git rm` the rename/delete conflicts; and a
constructor both sides extended takes **both** dependencies (upstream's and the fork's),
sorted.

## 3. The reconciliation commit

Land the conflict-resolving leftovers — leftover conflict tails in merged files
(`grep -rn '<<<<<<<'`), test expectations that upstream tightened for a different harness,
a service restored to the fork's coherent shape when the upstream side of its conflict
referenced a method the fork never answers — as ONE `fix: reconcile the fork onto
upstream/main` commit, each seam named in the body. Generated-file regenerations land as
their own commits beside it (`l10n: push …`, `chore(budgets): ratchet …`, `build: rebuild
bundles`), each with the repo's own documented command, never hand-edited.

**Regenerate last, in this order**: settle all source → `npm run l10n:push` (or the repo's
equivalent) → budget ratchet → final bundle rebuild. Each guard reads the tree as it
stands; a regeneration before the source settles goes red again.

## 4. Verify before pushing anything

1. The repo's unit suite and static analysis, green (`composer test:unit`,
   `composer lint:phpstan` — the baseline only shrinks).
2. The frontend build with its full prebuild guard chain, green.
3. `git diff --name-status backup/pre-rebase <rebase-tip> | grep -c '^D'` **is 0** — the
   diff against the backup must be upstream's delta and nothing the fork lost. (Diff to
   the post-rebase HEAD, not the backup, once the release commits land — those delete
   files on purpose.)
4. Upstream's headline fixes are present (spot-check one or two by file).

Then: force-push the rebased `main` (`--force-with-lease`, remote unchanged since the
backup), branch, and PR the follow-up work — a PR whose base is still the pre-rebase main
shows the whole upstream delta as its review, which is noise, not review.

## 5. Release prerequisites (the owner's half)

Before a fork's first `v*` tag can publish, the repo needs — once, by the owner:

- a **`release` environment** (`gh api -X PUT repos/<org>/<repo>/environments/release`)
  carrying the `APP_SIGNING_KEY` and `APP_SIGNING_KEY_PASSWORD` secrets;
- a **`v*` tag ruleset** restricting tags to the owner (`v-tags-owner-only` on the repos
  that have it).

Territorio found these already in place; IntraVox's had to be created mid-flight
(instalador #35). The shared workflow's header names the same list.
