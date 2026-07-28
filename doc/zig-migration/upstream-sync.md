# Upstream sync

This repository is an **experimental fork**. Upstream lives on Codeberg:

| | repository | default branch |
| --- | --- | --- |
| upstream | <https://codeberg.org/IPMITool/ipmitool> (`https://codeberg.org/IPMITool/ipmitool.git`) | `master` |
| this fork | <https://github.com/cataggar/ipmitool> (`origin`) | `main` |

The incremental Zig rewrite (tracking issue #2) runs for months, so the fork
drifts from upstream the whole time. `scripts/sync-upstream.sh` makes that
drift visible and routable: for every upstream change it says which
**migration unit** owns the file, and therefore which port issue has to deal
with it — a fix in a module that is still C can be applied as a patch, a fix in
a module that has already been rewritten in Zig has to be re-implemented there.

```sh
scripts/sync-upstream.sh                 # fetch upstream, print the delta
scripts/sync-upstream.sh --format markdown   # paste-able report
scripts/sync-upstream.sh --record        # after triaging: move the sync point
```

## When to run it

* **Weekly**, and always before starting work on a port issue that touches the
  files upstream just changed.
* **Before cutting any release or milestone** of the fork.
* From CI (issue #6) with `--check`, so an un-triaged upstream delta shows up
  as a failing job instead of being forgotten.

## What the script does

1. Adds (or verifies) a remote named `upstream` pointing at the Codeberg URL.
   Its push URL is set to `DISABLED-read-only-upstream` so an accidental
   `git push upstream` fails loudly. If the remote already exists with a
   different URL, the script reports it and stops instead of rewriting it;
   `--force-url` overrides that.
2. Fetches `+refs/heads/*:refs/remotes/upstream/*` with `--no-tags --prune`.
   `origin`, the current branch and the working tree are never touched.
3. Resolves the **sync point**: `--since REF` if given, otherwise the commit in
   `doc/zig-migration/upstream-sync-state.json`, otherwise the merge base of
   the fork and `upstream/master`.
4. Prints the commit delta, how many fork-only commits exist, and a per-file
   table mapped onto the migration units.
5. With `--record`, writes the new sync point into the state file. That is the
   **only** tracked file the script will ever write.

The script is strictly read-only otherwise: no checkout, reset, merge, rebase,
stash, clean, `git add` or push. It is safe to run from any branch, from a
linked worktree, and with a dirty tree.

### Options

| Option | Meaning |
| --- | --- |
| `--fetch` / `--no-fetch` | fetch upstream first (default) / use the refs already in the clone |
| `--since REF` | diff against `REF` instead of the recorded sync point |
| `--format text\|json\|markdown` | report format (`text` is the default) |
| `--record` | write the new sync point to the state file |
| `--check` | exit 1 when upstream commits are not reconciled yet |
| `--remote NAME`, `--url URL`, `--branch NAME` | override remote name, URL, upstream branch |
| `--upstream-ref REF`, `--fork-ref REF` | override either side of the comparison |
| `--state FILE` | use a different state file |
| `--force-url` | rewrite the remote URL when it differs |

Exit status: `0` success, `1` `--check` found un-triaged drift, `2` usage
error, network failure or any other error.

### Reading the report

```
 upstream head      : d62a996  2026-03-30  fru: Fix false failure when changing string length
 sync point         : d62a996  2026-03-30  (state file doc/zig-migration/upstream-sync-state.json)
 fork ref           : main (20ded31)
 merge base         : d62a996
 upstream commits   : 0 new since the sync point
 fork-only commits  : 3 not in upstream
 files changed      : 0 (+0/-0)
```

* **sync point** — the last upstream commit that was triaged into this fork.
  Everything after it is new work for us.
* **upstream commits** — how far behind the sync point is; this is the number
  `--check` fails on.
* **fork-only commits** — our own commits (README conversion, migration
  tooling, and eventually the Zig port). This number only grows.
* **changed files by migration unit** — one line per file: change type
  (`A`/`M`/`D`), path, insertions/deletions, and the upstream commits that
  touched it, grouped under the unit and the issue that owns it.

## Migration unit map

The script classifies every changed path into exactly one unit. Rules are
evaluated in this order (crypto beats transports, the build system beats the
directory it sits in):

| unit | paths | owning issue | port target |
| --- | --- | --- | --- |
| `crypto` | `src/plugins/lan/md5.[ch]`, `src/plugins/lanplus/lanplus_crypt*` | #9 | Zig crypto |
| `build` | `configure.ac`, `bootstrap`, any `Makefile.am`, `*.m4` | #5, #13 | `build.zig` |
| `frontend` | `lib/ipmi_main.c`, `src/ipmitool.c`, `src/ipmievd.c`, `src/ipmishell.c` | #12 | Zig front ends |
| `util` | `lib/helper.c`, `lib/log.c`, `lib/ipmi_strings.c`, `lib/ipmi_time.c` | #8 | Zig util layer |
| `commands` | the other `lib/*.c` (39 command modules incl. `dimm_spd.c`, `hpm2.c`) | #11 | Zig command modules |
| `transports` | `src/plugins/*` (`open`, `lan`, `lanplus`, `serial`, `usb`, `dummy`, `dbus`, `free`, `imb`, `lipmi`, `bmc`, `ipmi_intf.c`) | #10 | Zig transports |
| `headers` | `include/ipmitool/*.h` | #7 | interop seams / Zig types |
| `ci` | `.github/**`, `.woodpecker.yml`, `buildenv/**` | #6 | fork CI |
| `docs` | `doc/**` | – | manual pages, keep in sync by hand |
| `contrib` | `contrib/**` | – | not ported |
| `control` | `control/**` | – | packaging, not ported |
| `other` | anything else | – | judge case by case |

`lib/ipmi_main.c` is counted as a front end, not as one of the 39 command
modules: it is the shared CLI driver behind `ipmitool` and `ipmievd`.

## Triaging an upstream change

For every file in the report, decide exactly one of three outcomes.

1. **The file is still C in this fork** — apply the upstream change directly:

   ```sh
   git -C . show <upstream-sha> -- lib/ipmi_fru.c | git apply -3
   ```

   or cherry-pick the whole commit when it only touches C we have not ported
   yet. Re-run the oracle (`scripts/build-oracle.sh`) afterwards so the
   differential baseline includes the fix.

2. **The file has already been replaced by Zig** — do *not* patch the C. Read
   the upstream diff, re-implement the behaviour in the corresponding Zig
   module, and add a regression case to the golden test harness (issue #4) that
   fails before and passes after. Reference the upstream SHA in both the commit
   message and the test name so the provenance survives.

3. **The file no longer exists in the fork** (for example a transport we
   decided to drop) — skip it, and record *why* in the log below. A skipped
   upstream change must never be silent.

Mixed commits are normal: an upstream commit that touches `lib/ipmi_fru.c` and
`include/ipmitool/ipmi_fru.h` can be case 1 for one file and case 2 for the
other. Triage per file, not per commit.

When every file of the delta has a decision, move the sync point:

```sh
scripts/sync-upstream.sh --record
```

## State file

`doc/zig-migration/upstream-sync-state.json` is the tracked sync point:

```json
{
  "upstream_url": "https://codeberg.org/IPMITool/ipmitool.git",
  "upstream_branch": "master",
  "last_upstream_commit": "d62a996c8bad7b3f8d67ffe3742985a3c96ed218",
  "last_upstream_commit_date": "2026-03-30",
  "last_upstream_commit_subject": "fru: Fix false failure when changing string length",
  "fork_commit": "20ded3198e7131af358a8e39c65c00aecb266e87",
  "fork_ref": "main",
  "recorded_at": "2026-07-28T22:35:11Z"
}
```

It is seeded with the true merge base of `main` and `upstream/master`, i.e. the
last upstream commit this fork already contains verbatim. Commit the file
together with whatever the triage produced (patches, Zig changes, tests, or
just this doc's log row) so the record and the code move as one change.

## CI usage (issue #6)

```sh
scripts/sync-upstream.sh --check --format markdown >> "$GITHUB_STEP_SUMMARY"
```

Exit code 1 means "upstream moved and nobody has looked at it yet". Run it on a
schedule rather than on every push — it needs network access to Codeberg.

## Sync log

One row per sync. Append, never rewrite; this is the record that survives.

| date | synced range | files | decision summary | by |
| --- | --- | --- | --- | --- |
| 2026-07-28 | seed at merge base `d62a996` | – | Fork is level with upstream `master`; nothing to triage. Sync point seeded, tooling added (#15). | @cataggar |

Decision summary conventions: name the unit and the outcome, e.g.
"`commands`/`lib/ipmi_sel.c`: still C, cherry-picked `abc1234`" or
"`transports`/`src/plugins/lan/lan.c`: ported to Zig, re-implemented in
`src/zig/transport/lan.zig` + golden test `lan-retry-timeout`" or
"`transports`/`src/plugins/imb/imb.c`: dropped transport, skipped".
