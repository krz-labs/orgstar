# Roadmap status, 2026-11-26

Where the milestone work stands, so a session can pick it up at any point. Read `docs/plans/2026-11-21-roadmap-handoff.md` first: its repository rules, decisions and procedure still apply. This document adds what milestone 1 taught, what it left open, and what comes next.

## State

- `main` is in sync with gitbay. No worktrees, work branches or open merge requests.
- Milestone 1 (Reviews and cleanup) is closed: 32 issues, 30 merge requests (447–476).
- Milestone 4 (Commands and editing speed) is closed: 12 issues (#236 added during it; #156 closed with #142), 6 merge requests (479–484), about one day.
- Milestone 5 (Sync and files) is closed: 11 issues (#238 and #239 added during it), 10 merge requests (486–492, 494, 495), about two days, most of it on #153's four review rounds. #87 (OneDrive greyed out in the iOS folder picker) moved to the Backlog: still greyed out on 2026-11-26; re-test later, Graph API app-folder sync is the fallback.
- On `main` with everything merged: `swift test` (about 1,475 tests), both Xcode builds and every performance gate pass (three gate runs on 2026-11-27: 1 MB open 83–89 ms, typing p95 unchanged; new gates for Lint File and Lint All Folders).
- `v1.3.0` is tagged on the "Version 1.3.0" commit and covers milestones 1, 4 and 5. Nothing is uploaded: the App Store builds, the notarised download, the appcast and the cask are the owner's call. `scripts/release-mac.sh` tags and pushes `v<version>` itself, so for 1.3.0 skip or delete that step.
- Simulators: "iPhone 17", "iPad Air 11-inch (M4)" (iOS 27.0) and "Apple Watch Series 11 (46mm)" (watchOS 27.0). Reuse them; do not create others.

| Milestone | Open | Closed |
|---|---|---|
| 1 Reviews and cleanup | 0 | 32 |
| 2 Capture | 6 | 0 |
| 3 Agenda and planning | 9 | 0 |
| 4 Commands and editing speed | 0 | 12 |
| 5 Sync and files | 0 | 11 |
| 6 Formats, import and export | 6 | 0 |
| 7 Notes and knowledge | 3 | 0 |
| 8 Automation and extension | 3 | 0 |
| Backlog | 42 | 0 |

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

- A worktree other than the main checkout, or a local branch with commits not on `origin/main` is unfinished work. `git log origin/main..<branch>` shows it; the commit subjects name the issue. Continue it in that worktree rather than starting over.
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

### Merging safely

- Never chain branch or worktree cleanup to a merge command with `&&` alone: a refused fast-forward leaves the chain running on a different command's success. Read the merge request's state from gitbay (`gitbay mr show <n> --json`, `state: merged`) and clean up only then. A branch deleted too early can be recreated from its commit (`git branch <name> <sha>`) and pushed again; gitbay reattaches the open merge request.
- Rebuild a conflicted string catalog as `origin/main`'s file plus the branch's added keys, written with `json.dumps(d, ensure_ascii=False, indent=2, separators=(',', ': '), sort_keys=True) + '\n'`, which reproduces the committed file byte for byte.

### Security-sensitive changes

- Give encryption and similar work an independent review from an agent that sees the code and the requirement but not the author's report, and repeat it after each round of fixes until it says it is ready. #153 needed four rounds; each round's fixes introduced something the next found (a save race that lost another app's edits, titles leaking through clock history and shared subtrees).

### Timing tests

- Timing assertions belong in the gates (`ORGSTAR_GATES`, run serially and by the release scripts), not in the parallel `swift test`, where the Emacs oracle tests starve other tests to tens of seconds of wall time. The backlinks check moved there in MR 492.

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

## Decisions taken in milestone 4, for the owner to confirm or overrule

1. #135 as the design review recommended: iPhone key bar of ten buttons plus Plan (Schedule, Deadline, Tags), no sideways scrolling; Bold, Italic, Code in the selection's Format menu; a Commands button in the editor, reader and agenda; the More menu removed. Key bar buttons are about 36 pt wide and 44 pt tall; at larger text sizes fewer fit and the rest go under More.
2. Reader toolbar: Find, Edit, Commands; Outline and Export in its Commands list. iPhone editor toolbar: Find, Undo, Commands (plus Conflict and Resolve Sync Conflicts when they apply); Export, Export Subtree and Recovery Versions in Commands. iPad keeps Export and Recovery Versions in the toolbar.
3. Palette and iOS Commands recents and use counts come only from runs through the palette or the Commands list, not keys or menus.
4. `C-u` before a sequence with no binding of its own is the universal argument; only macro commands take it.
5. Mac preset macro keys: ⌃⌘R start, ⌃⇧⌘R stop, ⌃⌘M run (not checked against system shortcuts).
6. Snippets: TAB expands a trigger only where TAB has no other meaning at the caret (headings still cycle, tables still move); templates are snippets with `file = true` in `snippets.toml`.
7. Completion defaults: opens by itself and fuzzy only in the Doom preset; Emacs and Mac keep prefix matching and manual opening. Word completion keys: `M-/` (Emacs), `F5` (Mac), `C-n`/`C-p` in Doom insert state.
8. iOS candidates: with the on-screen keyboard, in a suggestion row in the key bar's place; with a hardware keyboard, the floating list.
9. Key bar configuration lives in `[key-bar]` in `config.toml` (`iphone`, `ipad` lists of command ids).

## Decisions taken in milestone 5, for the owner to confirm or overrule

1. #153: encrypt-on-save and `.org.gpg` are not behind orgstar+ (the existing Encrypt commands still are). Once a file is unlocked it keeps sealing until closed, whatever the setting. A heading inside an encrypted entry can't be archived or refiled on its own; Share Subtree shares it as an "Encrypted entry" placeholder. Exports and Emacs copies leave encrypted content out (Emacs copies are refused rather than asked). age is not supported.
2. #95: auto-commit per folder in Settings ▸ Git (download version), off by default; only files orgstar wrote; pull (`--ff-only`), then commit, then push.
3. #155: File ▸ History… replaces Recovery Versions… on the Mac.
4. #151: Replace in Files keeps a recovery version, not undo, for files that weren't open; renames change `config.toml` too while the dialog's checkbox is on (the default).
5. #148: no sync on leaving the app (iOS can't open another app while going to the background); a Shortcuts automation is documented instead.
6. #93: Handoff matches folders by iCloud path, then by folder name; nothing is advertised for encrypted files or buffers with decrypted entries.
7. #239: one app-wide "Use Face ID to Decrypt" (Touch ID on the Mac) in UserDefaults, undecided until the first typed passphrase or a launch with passphrases saved by an earlier version asks; Not Now records off and leaves earlier items unread but listed with Forget; only a passphrase that opens every encrypted message in the file is saved; turning off deletes every saved passphrase. The Mac quit prompt saves only while on and never asks.
8. The download version embeds the Developer ID provisioning profile (`~/Library/MobileDevice/Provisioning Profiles/orgstar_dev_id.provisionprofile`, valid to 2044, tied to the Developer ID Application certificate created 2026-10-10) and uses the protected Keychain like the App Store build. A new certificate means a new profile; `release-mac.sh` stops without one.

## Device checks owed

### From milestone 5

- Encryption: every build uses the protected Keychain; with Use Face ID to Decrypt on, Face ID or Touch ID is asked once per file (the simulator doesn't show the prompt); the question at the first typed passphrase and at the first launch after 1.2.0 with saved passphrases; the notarised download launches with the embedded profile; quit and close alerts on the Mac; the iOS notice and unlock screens; the clock title key across launches.
- Git: auto-commit against a real remote over SSH or the Keychain.
- Handoff between real devices in each direction; Working Copy installed with a real repository (its key, the sync chain, a commit with nothing changed); AirDrop, Mail and Messages from Share Subtree.
- iOS: the rename screen, the lint lists, Lint All Folders on a large real workspace.


### From milestone 4

- iOS with a hardware keyboard: Doom and Emacs macros, `F5` / `M-/` / Doom `C-n`, the floating completion list, snippet fields with TAB and S-TAB, key hints appearing in Commands on connect.
- iPhone: the feel of the 36 pt key bar buttons, the Plan menu, the Format edit menu with a pointer on iPad, the suggestion row while typing, VoiceOver on the row and the key bar.
- Mac: Edit ▸ Macros and its three keys in the running app; File ▸ New File from Template…; snippet field bands; a named macro in the palette after `macros.toml` reloads.


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

Milestones 4 and 5's questions are settled. Still open:


From the handoff, still unanswered:

- #115: an option on capture templates, or a separate quick-add field?
- #122: does snooze move only the notification, or rewrite the timestamp?
- #129: how closely to follow org-ql's syntax.
- #164: Beamer and reveal.js, or only the in-app presentation mode.
- #172: which package's card format to read and write.

New:

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

Milestone 4 took about one day against milestone 1's four and a half: well under its 0.9–1.1× estimate. It had no review phase, no usage-limit stops, few decisions for the owner, and most of it was testable on this Mac. Treat the other estimates as high by the same reasoning where those conditions hold, and not where devices or open questions set the pace. Of the rest, milestone 7 (small) and milestone 6 (mostly testable on the Mac) are the next cheapest to run well; milestone 2 is next in order but most dependent on devices.
