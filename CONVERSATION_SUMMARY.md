# Conversation Summary

**Working directory:** `/home/sieyes/baghdadPlane/flakes/nasExitGiScorp`
**Subject file:** `gengBowsArrow/runmanager/SPEC.md` (read-only evaluation; repository not modified except for this summary file, created on request)

---

## 1. Request: Evaluate the quality of `gengBowsArrow/runmanager/SPEC.md`

The spec describes `runmanager`, a Haskell CLI managing runs of the
`run-pi-microvm` script (from the `nasExitGiScorp` flake), tracked in a
PostgreSQL `run` table, with `run` and `list` subcommands.

The spec was read in full and cross-checked against the actual
`run-pi-microvm` CLI (`gengBowsArrow/pi-vm/microvm/runWserviceMicrovm.py`).

**Overall verdict:** a decent mid-level draft — good structure and testable
contracts, but not implementable without answers to several open questions.

### Strengths
- Types (3.0.x) separated from runtime behaviour (3.1+), cross-referenced by section number.
- API-key security handling stated clearly and consistently (only the path is passed; key never read/copied/logged).
- Explicit status lifecycle: `initializing → ongoing → done/terminated`, with per-state hooks.
- Concrete, testable `list` output contract (nushell `detect columns` pipeline example).
- CLI options in §3.3 verified to match the real `run-pi-microvm` interface.

### Contradictions and errors
1. Output column named three ways: `target` (3.0.6), `output` (3.1.1), `outputPath` (3.4.2).
2. §3.3 claims `--model` comes from a `model` *column*; no such column exists (it's in the runConfig).
3. `follows` is defined/validated (3.0.3, 3.0.4) but never used at runtime; "must be empty" seems to contradict its apparent purpose. Largest functional gap.
4. Impure `origin` = "nix store copy of flakeref including the new directories" — but the new run dir is empty, and empty dirs generally don't survive flake-to-store copies (esp. git flakes). Mechanism likely broken as written.
5. Type 3.0.2 (`runpath`) allows "latest", but DB runpaths are always numeric; "latest" belongs only to `follows` paths (3.0.3).
6. §4 example uses `STATUS == done`, but headers derive from 3.0.6's lowercase/camelCase column names — the example would fail.

### Underspecified areas
7. Fate of `run-pi-microvm`'s stdout (pi's JSON event stream) — never specified; arguably the run's main artifact.
8. Config precedence/names: env var and CLI option names missing; no precedence order; unclear if `--config` is optional when values come from env/CLI; 0600 enforcement unclear.
9. `run` table provisioning: fail vs. create if absent; exact DDL for "satisfying" the schema; how `id` is generated.
10. Concurrency/number reuse: both numbering schemes (filesystem count for impure, DB query for pure) are racy; terminated runs cause number reuse → `runpath` not unique; pure numbering isn't scoped by flake/origin.
11. Constraints on flakeref when `--pure` *is* set are unstated (3.1.1.1 implies it must already be a store path).
12. Terminated-run cleanup: is the temp workdir deleted? The `latest` symlink dangles after 3.4.1's directory deletion.
13. §3.4.2 ordering: contents "moved" to the store yet "also copied" to the flake — copied from where? Use "added to the store" and define order.
14. No crash/interruption recovery for runmanager itself (rows stuck at `initializing`/`ongoing`); "pi confirmed running" detection mechanism unspecified.
15. Vague phrases: "translated adequately" (units), timestamp format, `$TMPDIR` fallback, workdir creation responsibility, `list` row ordering, exit codes/errors.

### Editorial issues
- Broken numbering (no §3.2; 3.0.1 "syntax" under "Types"; five-level numbers like 3.1.1.0.0; all headings `###` regardless of depth).
- Typos: "atisfies", "valides", "does exists", spacing errors ("options .", "`<run number>`as").
- "an unrelated side-effect" (it isn't), "latest created empty directory" (confusing), duplicated "increment highest number" phrasing.
- `model` described as "three substrings separated by two forward slashes" rather than `provider/org/model`.
- `listedStatuses` letters defined only by example; invalid/duplicate letters undefined; suggest a `--statuses` CLI override.

### Top recommendations
1. Unify `target`/`output`/`outputPath`; fix the `model` "column" wording.
2. Specify `follows` runtime semantics (and reconcile "must be empty").
3. Specify capture of the JSON event stream.
4. Add a uniqueness/allocation rule for run numbers (e.g. unique `(origin, runpath)` among non-terminated runs).
5. Resolve the empty-directory-in-nix-store problem for impure `origin`.
6. Fill in operational details: config names + precedence, table DDL/creation, crash recovery, exit codes, timestamp format, `STATUS` vs `status`.

---

## 2. Request: Neovim techniques to fix the editorial issues (incl. renumbering)

All built-in Neovim, no plugins:

1. **Survey structure:** `:g/^#/#` (headings with line numbers); `:vimgrep /^#\+ /g % | copen` for a jumpable outline; treesitter foldexpr for markdown folds.
2. **Renumbering:**
   - Visual-block `g<C-a>`: select the final digit column of sibling headings → sequential increments (1, 2, 3, …). Plain `<C-a>`/`<C-x>` bumps one number; cursor position picks the dotted component.
   - Scriptable counter: `:let i=0` then `:g/^#\+ 3\.0\.\d\+/s/3\.0\.\zs\d\+/\=i/ | let i += 1`.
   - Derive heading level from dot count: `:g/.../s/^#\+ \(...\)/\=repeat('#', len(split(submatch(1),'\.'))+1).' '.submatch(1)/` (flatten >6-level numbering first).
3. **Cross-references:** `:vimgrep /\<\d\+\.\d\+\%(\.\d\+\)*\>/g % | copen` to review every dotted number; `:%s/\<3\.0\.4\>/3.1.4/gc` with word boundaries + confirm flag; or `cgn` + `.` for selective repeats. Renumber deepest sections first.
4. **Typos:** `:setlocal spell`, `]s`/`[s`, `z=`/`1z=`, `:spellrepall`; grammar slips ("does exists") via targeted `:vimgrep`.
5. **Whitespace:** `:%s/\s\+$//e`; collapse double spaces with inverse-global `:v/^    /s/\s\{2,}/ /ge` to spare 4-space-indented code blocks; `:%s/ \+\([.,]\)/\1/gc` for stray space-before-punctuation.
6. **Macros:** record with `qa … q`, replay with `@a`/`@@`; or `:g/pat/norm! …` to apply normal-mode edits per matching line.
7. **Safety:** `u` undoes each `:g`/`:s` pass atomically; `:earlier`/`:later` time-travel; `:set undofile`.

Suggested order: renumber deep sections → fix heading levels → fix cross-references via quickfix → mechanical passes (spelling, whitespace). Structure first, cosmetics last.

---

## 3. Request: Export this conversation

This file (`CONVERSATION_SUMMARY.md`) was created in the working directory.
No other repository files were modified.
