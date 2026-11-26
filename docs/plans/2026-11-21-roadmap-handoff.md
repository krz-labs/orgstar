# Roadmap handoff: orchestrating the milestone issues

For a session that coordinates subagents working through the open issues on gitbay (`krz/orgstar`), reviews what they submit, merges it and closes the issues.

The current state, what milestone 1 taught, the device checks owed and the effort estimates are in `docs/plans/2026-11-25-roadmap-status.md`. Read it after this document.

## State on 2026-11-21

- Version 1.2.0 is released. `main` is clean.
- 69 open issues: 54 in eight numbered milestones, 14 in Backlog, and #109 (code scanning findings from gitbay-bot, no milestone). #109 is out of scope for this work; leave it alone.
- Issue bodies are scoping notes written from the manual and keyword searches of the code. They were not checked against the implementations. Treat each as a starting point, and correct the issue when the code says otherwise.
- Nothing has been implemented. No branches or worktrees exist for this work.

Live list, which is the source of truth:

```bash
gitbay milestone list
gitbay issue list --state open --json
gitbay issue show <n>
```

## Milestones, in order

| Milestone | Open | Issues | Planned version |
|---|---|---|---|
| 1 Reviews and cleanup | 7 | #96 #97 #110 #111 #112 #113 #114 | 1.3.0 (fixes may ship as 1.2.x) |
| 2 Capture | 6 | #94 #115 #116 #117 #118 #120 | 1.4.0 |
| 3 Agenda and planning | 9 | #122 #123 #125 #126 #127 #128 #129 #131 #132 | 1.5.0 |
| 4 Commands and editing speed | 11 | #135 #136 #137 #138 #139 #140 #141 #142 #143 #145 #146 | 1.6.0 |
| 5 Sync and files | 9 | #87 #93 #95 #148 #151 #152 #153 #155 #158 | 1.7.0 |
| 6 Formats, import and export | 6 | #90 #159 #160 #161 #164 #166 | 1.8.0 |
| 7 Notes and knowledge | 3 | #168 #170 #172 | 1.9.0 |
| 8 Automation and extension | 3 | #173 #174 #175 | 2.0.0 |
| Backlog | 14 | #121 #133 #154 #162 #165 #167 #169 #171 #177 #178 #179 #180 #181 #182 | whichever minor they land in |

Versions are a plan, not a commitment. Every milestone is a minor release by semver. 2.0.0 is pencilled at milestone 8 because user-written commands (#173) would be the first public API. It moves earlier if the design review (#97) leads to a visible redesign; decide after that review reports. Do not put version numbers in milestone titles. Do not cut a release unless the user asks.

## Decisions already made

Do not reopen these without the user.

- **Milestones mix Mac and iOS by theme.** Shared code lives in OrgCore and OrgApp, which all app targets link. Each issue ends with a "Platforms" line.
- **Reviews first.** #96 (performance) and #97 (design) produce a dated report in `docs/` and one new issue per finding. #135 and #138 (where commands live on iOS and in the Mac preset) are to be settled with #97.
- **orgstar stays an org editor.** Markdown and plain text are a minimal fallback and are there for Denote users (#159, #160): highlighting, heading folding, the outline pane and search indexing. No structure commands, agenda, capture or export for Markdown.
- **Git on iOS goes through Working Copy** (#148). Built-in libgit2 and WebDAV sync were closed as wontfix.
- **Time zones:** nothing about zones is written to files. A display-only second zone is part of the timeline (#127).
- **Location:** closed as wontfix (privacy cost against low value).
- **User-written commands (#173) is a review only.** Its output is a written recommendation in `docs/plans/` and follow-up issues. No build work until the user has read it.
- **Mobile priorities:** capture without typing (voice with natural-language quick add) is the largest gain, then acting on entries without opening the app, then touch-first planning.
- **Desktop priorities:** planning on a large screen, editing speed, system integration, workspace maintenance.
- **Audience:** both people new to org and long-time Emacs users. A feature must not confuse the first group or be shallow for the second.
- Closed as wontfix, with reasons in each issue: #119 #134 #147 #149 #150 #157 #163 #176 #183 #184 #185. Merged: #124 into #123, #130 into #128, #144 into #138, #156 into #142.

## Open questions to put to the user when the issue comes up

- #122: does snooze move only the notification, or rewrite the timestamp?
- #115: an option on capture templates, or a separate quick-add field?
- #152: lint the current file first, or all folders from the start?
- #129: how closely to follow org-ql's syntax.
- #172: which package's card format to read and write (org-drill, org-fc, org-srs).
- #164: Beamer and reveal.js, or only the in-app presentation mode.

## Things to verify before work starts on an issue

These bodies say "check first" because the current behaviour is unknown:

- #118, #122, #123: `OpenCaptureIntent` sets `openAppWhenRun = true` (`Sources/OrgApp/WidgetIntents.swift`); it is the only intent that does. Find out whether an intent can edit a file without opening the app.
- #125: what agenda rows offer on swipe today.
- #131: what "Keep orgstar in the menu bar" shows today.
- #180: what the outline pane allows by drag today.
- #110: the manual's "Known differences from Emacs Org" section looks stale in at least three places; check each entry against the code.
- #120, #121, #174, #177: what the sandboxed Mac App Store build permits.

## Repository rules

From the user's instructions and `CONTRIBUTING.org`. Give these to every subagent.

- **Never push to `main`.** Branch, open a merge request, merge only when the full test suite is green on the branch.
- **Merge with `--strategy ff`.** The repository requires signed commits, so squash merges are refused. Rebase the branch onto `main` first. Delete the branch, locally and remotely, only after the MR shows `state: merged`; deleting the source earlier marks the MR `source_gone`.
- **gitbay is not GitHub.** Use the `gitbay` CLI; `gh` does nothing here. Parse `--json` output. Pass long text with `--file -` on stdin, or the command waits on an editor. `gitbay <noun> <verb> --help` gives real flags.
- **Commit messages** are short, state the change, and reference the issue: `Closes #N` or `Ref #N`.
- **No attribution to an assistant or tool anywhere:** not in commits, MR bodies, code comments, issues or docs.
- **Writing style:** plain, direct sentences for a knowledgeable reader. No before/after commentary in code comments or files.
- **Changes are surgical.** Touch only what the issue needs; match the surrounding style; no speculative options or abstractions. Mention unrelated problems instead of fixing them.
- **Files over 1,000 lines are fine.**
- **Tests:** there is no CI. Before an MR is opened, on its branch:

  ```bash
  swift test
  ```

  and, because `APPSTORE` is set only in the Xcode targets, both of:

  ```bash
  xcodebuild -project ios/Orgstar.xcodeproj -scheme 'Orgstar macOS' -destination 'generic/platform=macOS' -derivedDataPath .build/xcode CODE_SIGNING_ALLOWED=NO build
  ```

  ```bash
  xcodebuild -project ios/Orgstar.xcodeproj -scheme 'Orgstar iOS' -destination 'generic/platform=iOS Simulator' -derivedDataPath .build/xcode build
  ```

  A rebase before merging does not need another run. The orchestrator runs all three once on `main` after each batch of merges (see the procedure). For #96 and any change to parsing, indexing or highlighting, also run the performance gates:

  ```bash
  ORGSTAR_GATES=1 swift test -c release --filter GateTests
  ```

- **Behaviour is checked against Emacs.** Where a feature overlaps Org, add oracle tests as `docs/plans/2026-11-20-parity.md` describes ("How to use the Emacs oracle tests"). Where orgstar can't do what Org does, it reports that and leaves the file alone.
- **Each MR carries its tests and its manual changes** (`docs/manual/guide/`), and new user-facing strings go through the string catalog with German (`scripts/sync-strings.sh`, `scripts/localize.sh`, `l10n/`).
- **Disk:** check `df -h ~` before a large build and stop if under 20 GiB free. In a worktree, pass `-derivedDataPath` under the worktree. Reuse existing simulators; do not create new ones. When work is merged or abandoned, delete build output, `git worktree remove <path>`, then `git worktree prune`.

## Orchestration procedure

Before any work starts, free disk space. Measure what build output holds (`~/Library/Developer/Xcode/DerivedData`, `.build` here and in the other repositories under `~/git/krz/`, stale worktrees), delete what the user approves, and aim for 80 GiB or more free. Then build one worktree in full, measure it, and set the number of concurrent worktrees so free space stays above 20 GiB. Tell the user the number.

One issue at a time per set of files. Two subagents must never edit the same files concurrently; issues in one milestone often share files (the agenda views, the completion popup, the iOS editor screen), so check before running any in parallel.

For each milestone, in order:

1. **Order the issues into batches.** A batch is the issues worked at the same time, up to the worktree cap, with no files in common. Put dependencies first (#159 before #160; #142 before #137 and #145). #128 and #129 go to one subagent on one branch as one MR, after the user has answered #129's open question. Put the "verify first" checks ahead of the issues that depend on them.
2. **For each issue:**
   1. Read the issue and the code it touches. If the body is wrong or the feature partly exists, edit the issue (`gitbay issue edit <n> --file -`) before any work starts. If a listed open question applies, ask the user.
   2. Start a subagent in its own git worktree on a branch named for the issue. Its brief names the issue number, the files and modules involved, what done looks like (tests that fail before and pass after, manual pages to update, platforms to cover), and the repository rules above.
   3. The subagent implements, runs the tests and both Xcode builds, commits, pushes the branch and opens an MR:

      ```bash
      gitbay mr create --source <branch> --target main --title "..." --file -
      ```

      It reports the MR number, what it changed, what it tested, and anything it could not verify.
   4. **Review.** Read the diff yourself (`gitbay mr diff <n>`); do not take the report as proof. Check it against the issue, the rules above, and that tests and manual changes are present. Run the test suite on the branch if the subagent's run is in doubt. Send problems back to the same subagent.
   5. **Merge and close.** Rebase onto `main` if needed (commits must stay signed; push the rebased branch with `--force-with-lease`), `gitbay mr merge <n> --strategy ff`, confirm `state: merged`, delete the branch locally and remotely, remove the worktree. A `Closes #N` commit closes the issue; otherwise `gitbay issue close <n>`.
   6. File anything found along the way as a new issue in the right milestone, labelled `feature` (the only labels are `feature` and `wontfix`).
3. **After each batch has merged,** run `swift test` and both Xcode builds once on `main`. If anything fails, fix it through a new MR before the next batch starts.
4. **At the end of a milestone,** report to the user what merged, what was deferred and why, and the device checks still owed, and stop. Releases (`scripts/release-*.sh`, the appcast, version bumps) are the user's call.

Review issues (#96, #97, #173) are different: the subagent's output is a report file and a set of new issues, not a feature. Review the findings before any are filed, since each filed issue becomes work.

Some issues cannot be finished by code review alone: notification actions, widgets, the watch app, Lock Screen and Action button capture, Handoff, Pencil and voice input need a device or simulator run. Say in the MR what was exercised in the simulator and what still needs a device. The issue closes on merge like any other. Keep a list in the session of the device checks owed (issue, MR, what to try on the device) and show it to the user at the end of each milestone and whenever they ask. The user opens a new issue for anything a device check turns up.

## References

- `docs/manual/guide/` — what the app does today, chapter by chapter; each chapter's "not supported" section.
- `docs/plans/2026-11-20-parity.md` — the Mac App Store and iOS parity plan, module rules and oracle tests.
- `docs/design.md` — architecture.
- `docs/review-2026-10-05.md`, `docs/review-2026-10-13.md` — the form earlier review reports took.
- `CONTRIBUTING.org` — building, testing, releasing.
