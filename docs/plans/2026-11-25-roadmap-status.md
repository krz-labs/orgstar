# Roadmap status, 2026-11-25

Where the milestone work stands, so a session can pick it up at any point. Read `docs/plans/2026-11-21-roadmap-handoff.md` first: its repository rules, decisions and procedure still apply. This document adds what milestone 1 taught, what it left open, and what comes next.

## State

- `main` is at `c287e0e`, in sync with gitbay. No worktrees, work branches or open merge requests.
- Milestone 1 (Reviews and cleanup) is closed: 32 issues, 30 merge requests (447–476).
- On `main` with everything merged: `swift test` (1,240 tests), both Xcode builds and every performance gate pass.
- Not released. The code is past 1.2.0; the plan pencils milestone 1 as 1.3.0. Releasing is the owner's call.
- Simulators: "iPhone 17", "iPad Air 11-inch (M4)" (iOS 27.0) and "Apple Watch Series 11 (46mm)" (watchOS 27.0). Reuse them; do not create others.

| Milestone | Open | Closed |
|---|---|---|
| 1 Reviews and cleanup | 0 | 32 |
| 2 Capture | 6 | 0 |
| 3 Agenda and planning | 9 | 0 |
| 4 Commands and editing speed | 11 | 0 |
| 5 Sync and files | 9 | 0 |
| 6 Formats, import and export | 6 | 0 |
| 7 Notes and knowledge | 3 | 0 |
| 8 Automation and extension | 3 | 0 |
| Backlog | 39 | 0 |

#109 (code scanning) has no milestone and stays out of scope.

## Resuming after an interruption

Work may stop mid-issue. Before starting anything, find what is in flight:

```bash
git fetch origin
git worktree list
git branch -a
gitbay mr list --state open --json
gitbay milestone list
```

- A worktree under `.claude/worktrees/` or a local branch with commits not on `origin/main` is unfinished work. `git log origin/main..<branch>` shows it; the commit subjects name the issue. Continue it in that worktree rather than starting over.
- An open merge request is waiting for review and merge (procedure step 2.4 in the handoff).
- A worktree with no commits beyond `origin/main` and no changes can be removed.
- Remove a worktree with `git worktree remove -f -f <path>` if it is locked, then `git worktree prune`; delete its branch locally and on gitbay after the merge request shows `merged`.

## What milestone 1 taught

### Merging

- Every branch must be rebased onto `origin/main` before `gitbay mr merge <n> --strategy ff`; otherwise the merge is refused. Commits are signed; a rebase re-signs them. Push with `--force-with-lease`.
- Two merge requests that each pass can fail together. In milestone 1, one made `WorkspaceModel.backlinks` throw and another called it without `try`; git saw no conflict. Run `swift test` and both builds on the combined code before the last merge of a batch, not only on each branch.
- `l10n/Localizable.xcstrings` conflicts on almost every rebase when several branches add strings. Resolve by keeping both sides' keys; then check the file still parses (`python3 -c "import json;json.load(open('l10n/Localizable.xcstrings'))"`). Run `scripts/sync-strings.sh` once at the end of a milestone so the catalog is in the form the script writes.

### Testing

- Batch the full test run: once on the combined code of a batch, before its last merge.
- Timing tests must not depend on machine load. Compare against something load cannot move (the fastest of several interleaved rounds; a spin long enough that "not stopped" is unmistakable), or assert on behaviour (which thread did the work) instead of durations. Two such tests were fixed in milestone 1.
- Take performance gate numbers on a quiet machine (`uptime` load under about 5). The 1 MB open gate is at 85–90 ms against 100 ms; under load it misses.
- Random tests use fixed default seeds; `ORGSTAR_SEED=<n> swift test` runs another.

### Running agents in parallel

- One worktree per agent, on files no other agent touches. Name the files each agent owns and the ones it must not edit; overlapping files cost a rebase conflict at best.
- This Mac (16 GB) runs about four full builds at once. Past that it swaps and every build slows; load averages of 400 were seen. A worktree after `swift test` and both Xcode builds holds 10–12 GB.
- Only one agent may use a given simulator at a time. Assign them.
- An agent stopped by a usage limit can be resumed; its worktree and commits survive. A worktree with no commits may be removed by the tool that created it; recreate one on the branch.
- Ask agents for screenshots in the scratchpad, not the repository, and look at a few before merging: two defects in milestone 1 (images 80 pt wide, a clipped icon on onboarding) were found only that way.

### Writing issues

- Issue bodies were often wrong about what exists. Check the code first and correct the body.
- Every follow-up found during a fix was filed as its own issue (Backlog unless it blocks something). #225–#235 came from milestone 1.

## Decisions taken in milestone 1, for the owner to confirm or overrule

1. Agenda: one row layout for Mac and iOS (the Mac's left column; iOS's line of tags and keywords above the title; Overdue under Today). The iOS agenda bar is `‹ Today [span] ›`.
2. Repeated agenda grid lines: fixed by a new default for the grid setting, so existing installs keep the old value.
3. Mac first run starts on Mac keys unless an Emacs or Doom configuration is found. The App Store build probably always starts on Mac keys.
4. Complete at Point is `⌥Esc` in the Mac preset; `⌃Space` belongs to input sources.
5. Every echo-area message stays until the next key, not only errors.
6. "Act at Point (C-c C-c)" is renamed "Update at Point".
7. "Commands" (Mac toolbar, iOS) and "Command Palette…" (Mac menu) still name one thing. Open.
8. Kanban: `⇧←` / `⇧→` move a card between columns.
9. Comparison sheets use the theme's TODO and DONE colours for removed and added lines.
10. Twelve of fourteen ported themes have a lighter secondary text colour (4.5:1). The watch uses keyword colours by kind, not the phone's theme.
11. iOS: the icon set (pencil for Edit); one message panel, top in the editor, bottom elsewhere; heading tags drawn at the right edge.
12. iPad: a sidebar with "All Folders"; Settings on `⌘,`; the Org menu lists commands that refuse on iOS.
13. #112: export scope and body only are kept per file and used by the export commands.
14. #114: `<<name()>>` is refused when tangling.
15. #195: TAB doesn't realign after a row was changed and left another way.
16. #208: script sandboxing is off on four Xcode targets so a build phase can trim SwiftMath's fonts.

## Device checks owed

By the owner's rule, an issue closes on merge and its device checks are tracked here. A problem found becomes a new issue.

### At the next release

- Mac App Store and iOS archives build, export and pass App Store Connect validation with the re-signed SwiftMath bundle (#208).
- Notarisation passes on the stripped Developer ID binaries; keep `orgstar-<version>-dSYMs.zip` from `.build/release` (#207).
- A Sparkle update from the previous version works.
- Run the release on a quiet Mac; the release scripts now stop on a gate miss (#193). In the App Store scripts the gates run inside appstore-kit's preflight, tested only against a stand-in.
- Upload the German Mac and iPhone screenshots (`ios/AppStore/screenshots/de/`) by hand. A German set still needs a 13" iPad, a paired watch and a search shot. The iPhone 6.9" set is the 6.3" set scaled up.

### Mac

- Org submenus, Help ▸ orgstar Manual and Help ▸ Keys, Help search, View ▸ Customize Toolbar.
- `⌥Esc` completion; a message clears on the next key.
- Return, Escape and Tab in the agenda's prompt; Escape in the column view's prompt.
- A large file opens quickly; the `#+STARTUP` options (`noindent`, `hidestars`, `inlineimages`, `latexpreview`, `shrink`) at the top and far down; syntax highlighting unchanged.
- Typing in a large workspace; the backlinks pane updates on heading change, save and rename; the inspector follows edits; the agenda picks up a file saved in another app.
- Export settings per file; `C-c C-e C-s` / `C-b` in the Emacs and Doom presets.
- Inline images: selection across an image, a folded heading with an image, an image beside LaTeX, dark appearance.
- Doom: `C-e` / `C-y`, `zl` / `zh` with truncation on, `&` / `g&`, the `z` fold keys, `g;` after typing and after undo.
- The `:post` and `<<name()>>` examples in `11-code-blocks.org`; a `:post` block with `:eval query` shows both blocks.
- Kanban keys; a folder dropped on the sidebar in the App Store build.
- The mode line's branch after a `git checkout`; no `.git/HEAD` reads in the background.
- Error alerts after deleting `index.sqlite` or making an open file unreadable.

### iPhone

- 1 MB and 10 MB files: typing feel, open time, whether the watchdog ends the app at 10 MB.
- The share sheet end to end and its error path; a watch capture arriving while a capture sheet is open.
- Export Body Only; German "Nur Inhalt".
- Widgets on the Home and Lock Screen, tinted mode, locked and unlocked orgstar+; complications; the Live Activity in German.
- org-protocol from Safari; a `config.toml` in iCloud that isn't downloaded; tapping an iCloud file starts the download; the orgstar+ load failure.
- Find with a hardware keyboard; the key bar's feel; the agenda at iPhone width.
- iOS and Mac App Store: an Emacs Lisp or JavaScript `:post` chain runs; one reaching `sh` is refused with nothing written.

### iPad

- The menu bar with a keyboard and pointer; Stage Manager resizing; several windows.

### Accessibility, both platforms

- VoiceOver announcements and rows; Increase Contrast; Differentiate Without Colour.

### From the performance review

- The twelve steps in section 7 of `docs/review-2026-11-21.md` (launch, memory, widgets, watch, Live Activity, energy, sync folders, Mac cold launch, hangs and leaks, download sizes, the M1 Air gate run).

## Open questions before the next milestones

From the handoff, still unanswered:

- #115: an option on capture templates, or a separate quick-add field?
- #122: does snooze move only the notification, or rewrite the timestamp?
- #129: how closely to follow org-ql's syntax.
- #152: lint the current file first, or all folders from the start?
- #164: Beamer and reveal.js, or only the in-app presentation mode.
- #172: which package's card format to read and write.

New:

- #135 and #138: the design review's recommendations are posted as comments on each. #138 is partly done (palette selection, first run, menus). Confirm the rest before milestone 4.
- #229: is 10 MB a supported file size?

## Estimated effort, relative to milestone 1

Milestone 1 took about four and a half days, 30 merge requests and about 35 agent runs. It was mostly fixes to findings that named the file and the fix, checked on this Mac. Later milestones are new features with more decisions and more checks that need a device. Estimates are from the issue titles and scoping notes, not from the code, and are ±50%.

| Milestone | Effort | Main cost | Limits |
|---|---|---|---|
| 2 Capture | 0.6–0.8× | Voice on iPhone and Watch, natural-language quick add, Live Text, Pencil sketches, Lock Screen and Action button, Mac Services | Almost all needs a device. #115. |
| 3 Agenda and planning | 1.2–1.5× | Timeline with time blocking and a second zone, month grid with drag, query language with triage and weekly review, completing from widgets and watch | #129 sets the size. #122. Widgets and watch need devices. |
| 4 Commands and editing speed | 0.9–1.1× | Snippets and templates, macros kept across restarts, completion (auto, fuzzy, buffer words, index), iOS key bar and suggestion row | Testable on the Mac with the Emacs oracle. #138 partly done. |
| 5 Sync and files | 1.2–1.5× | Working Copy, Handoff, git auto-commit, find and replace across files, lint, whole-file encryption, file history | Writes and encrypts user files; review the encryption for security. Two devices and a third-party app. #152. |
| 6 Formats, import and export | 0.9–1.2× | Pyodide in the sandboxed builds, minimal Markdown and Denote, Markdown and Obsidian import, slides, printing | Pyodide's size works against #207–#209. #164. |
| 7 Notes and knowledge | about 0.5× | org-roam gaps, citations with Zotero, spaced repetition | #172. Zotero needs a running instance. |
| 8 Automation and extension | 0.3–0.5× | #173 (review only), command-line tool, x-callback-url | #173's recommendation gates build work; the sandbox may rule out the command-line tool. |

Milestones 2–8 together: about five to six times milestone 1. The Backlog's performance items (#197–#203 and others) are about one milestone 1 more.

Milestone 4 is the cheapest to run well next, being testable on this Mac; milestone 2 is next in order but most dependent on devices.
