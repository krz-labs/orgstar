# User-written commands: recommendation

Review for #173. It compares the ways users could add their own commands and recommends one, with a phased plan. Nothing here has been built. Everything comes from reading the code on `main` at e3fb313; the App Store rules are from the published guidelines and need a check of their current wording before the first submission that includes the feature.

## Recommendation in brief

- **Language:** JavaScript.
- **Engine:** a Web Worker in a hidden `WKWebView`, the pattern `PythonBlocks` uses for Pyodide, not the in-process `JSContext` that `JavaScriptBlocks` uses. A worker can be terminated, so a command gets a real time limit, and its memory sits in WebKit's process, not the app's.
- **Files:** `commands.toml` in the configuration folder declares each command (id, title, file, function, context); the code is in `commands/*.js` beside it. Commands get ids `user.<name>` and show up wherever command ids are used: the palette, `keymap.toml`, the iOS Commands list and `[key-bar]`.
- **API:** versioned (`api = 1`), asynchronous, and limited to what orgstar already models. Version 1 gives the current buffer's text, selection, outline and settings; returns edits that apply as one undo step at the revision they were computed against; and offers prompts, echo-area messages and copying to the kill ring. No file system, no network, no native platform APIs.
- **Trust:** the code-block trust prompt, extended to whole script files. Trust is kept per device by content hash, so a script synced from another device, or changed by sync, asks again before it runs.
- **Same everywhere:** the download build, the Mac App Store build and iOS run the same commands with the same powers.
- **Not chosen:** the Emacs Lisp interpreter as the command language, Lua, WebAssembly, and Shortcuts as the only route. Reasons are under "Options rejected".

Three phases, about 7–10 working days in all. Phase 1 alone (2 issues, about 4–5 days) is a usable feature.

## What exists today

### Commands and dispatch

- `Sources/OrgCore/Commands/Command.swift` defines `OrgCommand`: an `id`, a `title`, `applies(in:)` and `run(in:) -> CommandStep`. A command is a pure function of `EditContext` (revision, text, parse tree, UTF-16 selections, `now`, calendar, prompt answers, hidden ranges, `EditingOptions`, known tags, `lastCommand`). It never reads the clock or the file system.
- `CommandStep` is `.commit(EditResult)`, `.prompt(Prompt)`, `.failed(String)` or `.external(ExternalRequest)`. `EditResult` carries `baseRevision`, non-overlapping `TextEdit`s, an optional new selection and `Effect`s (`message`, `copy`, `fold`, `sparseTree`, …). A result is applied only at its base revision. `.external` already covers work done outside the text whose result comes back as an edit (Babel, Emacs tables, tangling).
- `Commands.all` is the registry of OrgCore commands. `Sources/OrgEditorAppKit/EditorCommands.swift` wraps them with view, edit, find and app actions for the Mac (`EditorCommand.Action`), and adds `namedMacros(_:)`.
- Named keyboard macros (`NamedMacros` in `Sources/OrgCore/Keymap/KeyboardMacros.swift`) are the one kind of user-defined command today: kept in `macros.toml`, given ids under `macro.named.`, listed in the palette, bindable in `keymap.toml`, and accepted by `MobileEditor.offered` on iOS (`Sources/OrgstarMobile/MobileEditor.swift`, the `NamedMacros.commandPrefix` case). User commands should follow this precedent.
- Key bindings: `Keymap(toml:problems:commands:)` in `Sources/OrgCore/Keymap/Keymap.swift` reads `keymap.toml` and reports bindings to unknown ids; `KeyContext` names the `when` contexts (`heading`, `table`, `item`, `region`, `src`, `timestamp`, `property`, …). `KeymapLoader` layers the file on a preset (`PresetEmacs`, `PresetDoom`, `PresetMac`).
- The palette ranks by `FuzzyMatch` plus `CommandUsage` (`Sources/OrgApp/CommandRanking.swift`) and groups by id prefix. Titles go through `CommandTitles` for the string catalog; user titles would be shown as written.
- iOS: `Sources/OrgstarMobile/CommandList.swift`, `AppMenus.swift` and `KeyBar.swift` list commands by id, filtered by `AppStoreCommands.hidden`; `[key-bar]` in `config.toml` lists ids.

### Code that already runs user code

- **JavaScript:** `Sources/OrgApp/JavaScriptBlocks.swift` runs `js` blocks in an in-process `JSContext` with a Node shim written in JavaScript. The shim refuses `fetch`, `crypto`, storage and the rest of Node and the web platform, so blocks have no file or network access. Its header says what matters most here: the public JavaScriptCore API cannot stop a running script. A timed-out run returns at once, but its thread keeps running until the app quits (`evaluate`, `runHere`, `Abandoned`).
- **Python:** `Sources/OrgApp/PythonBlocks.swift` runs Pyodide in a Web Worker of a hidden `WKWebView`, with the page and files served by a `WKURLSchemeHandler`. A timeout or cancel calls `worker.terminate()`, which does stop a running script. It sets no Content-Security-Policy; the command host must (see Safety).
- **Emacs Lisp:** `Sources/OrgCore/Config/Elisp.swift` (with `ElispForms`, `ElispLibrary`, `ElispRegex`, `ElispTime`, `Lisp.swift`) is an evaluator over `Sexp` for diary sexps, table formulas, header arguments, capture templates (`CaptureLisp.swift`), `elisp:` links and Emacs Lisp blocks where Emacs isn't available. It has about 180 functions and special forms, a step limit of 1,000,000 and a depth limit of 1,600, and throws `Unsupported` for anything else. It has no buffer primitives (`point`, `insert`, `goto-char`, `re-search-forward` on a buffer), no Org API (`org-entry-get`, `org-map-entries`, `org-element-*`), no `interactive`, no hooks or advice. `EmacsBuffer` (`Sources/OrgCore/Commands/EmacsBuffer.swift`) has Emacs's point and marker rules but is Swift used to port Org commands, not something Lisp can reach.
- **Trust:** `Sources/OrgApp/TrustStore.swift` keeps SHA-256 hashes of path plus content in `trusted.json` under `WorkspaceModel.defaultDirectory` (Application Support, not the configuration folder, so not synced). The prompt is "Run this … block?" with yes, no and always (`Sources/Orgstar/ContentView.swift` around line 1262, `Sources/OrgstarMobile/EditorScreen.swift` `run(_:)`). Any change to the content asks again.
- **Gate:** running blocks needs orgstar+ (`ProAccess` `.babel`; `TableBlocks.allowed` on iOS).

### Configuration folder

- `UserConfig.directory` (`Sources/OrgApp/UserConfig.swift`): `ORGSTAR_CONFIG_DIR`, `$XDG_CONFIG_HOME/orgstar` or `~/.config/orgstar`; in the Mac sandbox only paths inside the container, unless a folder is chosen. `ConfigFolder` (`Sources/OrgApp/ConfigFolder.swift`) keeps a chosen folder as a bookmark, security-scoped in the sandbox; on iOS it is the synced copy of the Mac's folder.
- Mac: `ConfigSync` (`Sources/OrgApp/ConfigSync.swift`) watches the folder with FSEvents, reapplies `config.toml`, reads `snippets.toml` and `macros.toml`, collects problems and publishes `changedFile`.
- iOS: `MobileModel` (`Sources/OrgstarMobile/MobileModel.swift`) resolves the bookmark at launch, reads the folder in `readConfig`, and reloads on any change through a `FolderPresenter` (`watchConfig`). Files in iCloud may not be downloaded yet; the device checks list "a `config.toml` in iCloud that isn't downloaded".
- Files there today: `config.toml`, `keymap.toml`, `capture.toml`, `views.toml`, `macros.toml`, `snippets.toml`, `default-theme.toml` (`docs/manual/guide/13-configuration.org`). Each reports problems by file and key.

### Shortcuts and App Intents

- `CaptureIntent` (`Sources/Orgstar/CaptureIntent.swift`, `Sources/OrgstarMobile/CaptureIntent.swift`) with an `AppShortcutsProvider`; `OpenCaptureIntent`, `ClockToggleIntent` and the widget and control configuration intents (`Sources/OrgApp/WidgetIntents.swift`); `ClockOutIntent` (`Sources/OrgApp/ClockActivity.swift`). None takes the editor's buffer or caret. #175 (x-callback-url) and #118 cover more automation from outside.

## Options

### Language

| | JavaScript | Emacs Lisp subset | Lua | WebAssembly | Shortcuts only |
|---|---|---|---|---|---|
| Engine exists | Yes: JavaScriptCore in-process, WebKit workers (Pyodide) | Yes, in OrgCore | No; a C library and a new bridge | WebKit runs it; no toolchain for users | Yes, system |
| Who can write it | Most programmers; many Emacs users | Emacs users, who will expect all of Emacs Lisp | Neovim users; few Emacs users | Only via another language's compiler | Anyone, but only coarse steps |
| Strings vs OrgCore offsets | UTF-16, same as OrgCore | Swift strings; bridgeable | Bytes; UTF-8 offsets differ from OrgCore's UTF-16 | Bytes | n/a |
| Can be stopped | Worker: yes. In-process: no | Yes (step and depth limits) | Yes (count hook, allocator limit) | Worker: yes | n/a |
| Access to buffer and caret | Through the API | Would need a buffer and Org API written from scratch | Through the API | Through the API | No |
| App Store route | WebKit / JavaScriptCore: the long-standing permitted route | Interpreter in the binary, user code | Interpreter in the binary, user code | WebKit | Native |

### Engine for JavaScript

- **In-process `JSContext` (as `JavaScriptBlocks`).** Synchronous, a few milliseconds to start, and the shim's refusal of web and Node APIs could be reused. But a loop that never ends keeps a thread spinning until the app quits, a script that allocates without bound gets the app killed (on iOS by jetsam, losing up to a second of unsaved typing), and on iOS a third-party app's JavaScriptCore runs without the JIT. `JSContextGroupSetExecutionTimeLimit` exists only in a private header, which App Review rejects.
- **Web Worker in a `WKWebView` (as `PythonBlocks`).** Asynchronous; a first start of a few hundred milliseconds, then a round trip of a few milliseconds plus the cost of sending the buffer (about 10–30 ms for 1 MB, to be measured in phase 1). `terminate()` stops a running script; an out-of-memory script takes down WebKit's content process, which `webViewWebContentProcessDidTerminate` reports, and not the app. WebKit's content process has the JIT on iOS. Network and file access must be shut off explicitly, since workers have `fetch`, `XMLHttpRequest`, `WebSocket` and `importScripts`.

The worker's costs (asynchrony, start-up) are acceptable for commands run from keys, the palette and the key bar, and `ExternalRequest` already models asynchronous work whose result comes back as an edit at a base revision. They rule out per-keystroke hooks, which this recommendation leaves out anyway.

## Recommended design

### Files

```
~/.config/orgstar/
  commands.toml
  commands/
    review.js
    dates.js
```

`commands.toml`:

```toml
api = 1

[[command]]
name = "weekly-review"        # id user.weekly-review
title = "Start Weekly Review"
file = "review.js"            # in commands/
function = "weeklyReview"     # an exported async function
when = "heading"              # optional; a KeyContext name; default: everywhere
timeout = 5                   # optional, seconds; default 2, at most 30
```

`commands/review.js`:

```js
export async function weeklyReview(org) {
  const heading = await org.heading()
  if (!heading) return org.fail("Not on a heading")
  const week = await org.prompt({ message: "Week: ", initial: "W48" })
  return {
    edits: [{ from: heading.end, to: heading.end, text: `** Review ${week}\n` }],
    message: "Review added",
  }
}
```

- The manifest is read without running any code, so the palette, `keymap.toml` validation and `[key-bar]` know the ids and titles even before a file is trusted, and `applies(in:)` comes from `when` through `KeyContext.holds`, synchronously.
- Problems are reported like the other files: `commands.toml: command weekly-review: no file commands/review.js`, `commands.toml: api 2 needs a newer orgstar`.
- Files in `commands/` are ES modules and may import each other by relative path, served by the scheme handler from that folder only.
- Mac: `ConfigSync` reads the manifest with the other files and reloads it on change. Mac App Store build: the same, from the container's folder or the chosen one. iOS: `MobileModel.readConfig` and the `FolderPresenter` reload; a script file that iCloud hasn't downloaded is reported and its download started, as `config.toml` should be.

### Integration

- OrgCore gets a `UserCommand: OrgCommand` built from a manifest entry. `run(in:)` returns `.external(.userCommand(…))` with the entry and the context; it is never `.commit` directly.
- `DocumentSession` (Mac and iOS share it) handles the request like Babel: it asks for trust if needed, sends the context to the worker, waits, validates the returned edits (in range, non-overlapping) and commits them as one `EditResult` at the base revision, so an edit made meanwhile refuses the result with "The file changed; try again." The edit is one undo step.
- Prompts from the script use the closure-based prompt the trust prompt already uses (`PromptRequest` on iOS, the minibuffer on the Mac), with `Prompt`'s choices, `requireMatch` and `date`. Time spent in a prompt doesn't count against the timeout.
- `EditorCommands.all` appends user commands as `namedMacros(_:)` does; `MobileEditor.offered` accepts the `user.` prefix; `CommandUsage` records them like any palette run.
- Cancel Running Task (`app.babel.cancel`) also cancels a running command.

### API version 1

All calls are asynchronous; `org` is passed to the command function.

| Call | Gives | Emacs counterpart |
|---|---|---|
| `org.text()` | The buffer text | `buffer-string` |
| `org.selection()` | Selections as UTF-16 `{from, to}`, main caret first | `point`, `region-beginning`, `region-end` |
| `org.heading(at?)` | The heading at a position: level, keyword, priority, title, tags, `start`, `end`, planning, properties | `org-entry-get`, `org-get-tags`, `org-get-todo-state` |
| `org.outline()` | Every heading as above, in order | `org-map-entries` |
| `org.file()` | The file's path relative to its folder, or null | `buffer-file-name` |
| `org.settings()` | TODO keywords, tags, `EditingOptions` values the command may need | `org-todo-keywords`, `org-tag-alist` |
| `org.prompt({message, initial, choices, requireMatch, date})` | The answer, or throws when canceled | `read-string`, `completing-read`, `org-read-date` |
| `org.message(text)` | Shows text in the echo area | `message` |
| `org.fail(text)` | Ends the command with nothing changed and the text shown | `user-error` |

The function returns `{edits, selection, message, copy}`, all optional. `edits` are UTF-16 offsets in the text the command was given; JavaScript strings are UTF-16, so offsets need no conversion.

Rules for the version:

- Additions within version 1 are compatible; a script may test for a call before using it.
- A change that breaks a version-1 script is version 2. The app keeps running version 1 for at least one major release after version 2 ships.
- `api` in `commands.toml` is required; a missing or newer value is a problem, and those commands are not registered.

### Safety

- **No file system or network.** The worker page and its script responses carry `Content-Security-Policy: default-src 'none'; script-src orgstar-commands:` (scheme name to be chosen), which applies to workers. A `WKContentRuleList` blocks every load not on that scheme. Before the user module loads, the worker deletes `fetch`, `XMLHttpRequest`, `WebSocket`, `EventSource`, `importScripts`, `indexedDB` and `caches` from its global scope, as a second layer. The scheme handler serves only files under `commands/`, and resolves symlinks before checking.
- **No native platform APIs.** Commands get nothing beyond the table above: no notifications, calendar, contacts, location, pasteboard reads or Shortcuts. Copying goes through the existing `Effect.copy`.
- **Trust per script file, per device.** The first run of a command from a file asks: "Run commands from commands/review.js? They can read and change the file you run them in." Choices: Run Once, Always, Don't Run. Always stores the file's hash in `TrustStore`; any change to the file, including one arriving by sync, asks again. `trusted.json` stays in Application Support, so a script synced from another device runs on this one only after it is approved here. Imported modules count as part of the file: the hash covers the entry file and every file it imports.
- **Time.** A run that passes its timeout (default 2 s, at most 30 s, excluding prompts) or is canceled terminates the worker and starts a new one; nothing is written. The message names the command and the limit.
- **Memory.** A script that exhausts memory ends WebKit's content process, not the app; the run fails with a message and the next run starts a new web view.
- **Encrypted entries.** Commands are refused in a buffer that holds decrypted entries, as Handoff and exports already treat them, so a script can't copy plaintext elsewhere in the file. Revisit if users need it.
- **What a synced script may do.** Exactly what a local one may, after it is approved on this device: read and edit the buffer it runs in. In phase 2, workspace reads and capture need a second approval (below).

### Phase 2: composition and the workspace

- `org.run(id)` runs a built-in command at the current state and resolves with the new text and selection, so a script can compose `org.todo.cycle`, `org.heading.insert` and the rest. All changes of one user command, its own and those of the commands it ran, form one undo step. Commands that need the app (`app.*`) are refused in version 1 of this call, except those listed as safe.
- Keyboard macros record and replay user commands, waiting for each to finish before the next key.
- Read-only workspace access: `org.search(query)` over the index (`OrgIndex`), `org.outlineOf(path)` for another file in an added folder, and agenda entries for a span.
- `org.capture(templateKey, text)`, which runs a `capture.toml` template through the existing capture code: the only way a command writes to another file.
- These four calls need `workspace = true` on the command in `commands.toml`, and the trust prompt says so ("They can also read every file in your folders and capture to them").

### Phase 3: hooks

- `[[hook]]` entries in `commands.toml` for `after-todo-state-change` (Org's `org-after-todo-state-change-hook`) and `capture-before-finalize` (`org-capture-before-finalize-hook`). A hook runs after the built-in command commits, gets the entry and the old and new state, and its edits apply as a separate undo step at the new revision.
- No per-keystroke hooks (`post-command-hook`, `after-change-functions`, `post-self-insert-hook`): the worker round trip is too slow for them, and a bad hook would break typing.

## App Store rules

### iOS and Mac App Store

- **Guideline 2.5.2** requires apps to be self-contained and not to download, install or execute code that introduces or changes features. The developer agreement's section on executable code bars downloading executable code and allows interpreted code only if it doesn't change the app's primary purpose, doesn't create a store or storefront for other code, and doesn't bypass signing, the sandbox or other OS security.
  - The design fits: the app downloads nothing. Scripts are files the user writes or copies into their own configuration folder, run in WebKit, which is the route Apple has always allowed for interpreted code. orgstar's App Store builds already run user-written JavaScript, Python in Pyodide and Emacs Lisp from the user's files, and Drafts, Scriptable and Obsidian ship user scripting on iOS.
  - The review notes and the App Store description should name the feature ("define your own editing commands in JavaScript") so it is part of the advertised purpose.
- **Guideline 4.7** covers software the app offers that isn't in its binary: HTML5 mini apps and games, streaming games, chatbots and plug-ins. Its conditions (an index of the software, content filtering and reporting, in-app purchase for digital goods, 4.7.2's ban on exposing native platform APIs without Apple's permission, 4.7.3's per-instance consent for data sharing) apply once the developer offers the software.
  - orgstar should not offer it: no in-app gallery, no install from a URL, no orgstar-hosted collection. Users share scripts the way they share `keymap.toml`, through their own repositories.
  - Keep 4.7.2 in mind regardless: the API exposes orgstar's own model (buffer, outline, prompts, capture), not native frameworks. Any future call that would reach one (notifications, calendar, location) needs this rule checked first.
- **Mac App Store sandbox.** Commands start no processes (the sandboxed build refuses `sh` blocks for the same reason) and reach files only through the API, so the sandbox needs no new entitlements.
- **Check before the first submission:** the current text of 2.5.2, 4.7 and the developer agreement's executable-code section, since their numbering and wording change between revisions.

### Download build

No store rules apply, but it gets the same API and nothing more (no shell, no Emacs process, no file access), so a command works unchanged on every device the configuration folder syncs to.

## What Emacs users would expect

### What they would want to port

- Small interactive commands from their `init.el`: insert a dated heading, set a property from a prompt, toggle a tag, clean up a list, convert a region. Version 1 covers these.
- Commands built from Org's own (`org-todo`, `org-schedule`, `org-insert-heading`): phase 2's `org.run`.
- `org-map-entries` loops over a file: `org.outline()` in version 1; over files, phase 2's `org.search`.
- Hooks on TODO state changes and capture: phase 3.
- Custom agenda skip functions and agenda commands that run code per entry: not planned. Each entry would need a worker round trip; the saved views in `views.toml` and #129's query language are the route.

### What would mislead them

- **Calling it Lisp, or reading `.el` files.** The interpreter has about 180 functions and no buffer or Org API. Every `defun` from an `init.el` would hit `save-excursion`, `re-search-forward`, `org-element-map` or a package (`dash`, `s`) and fail. Offering Lisp would promise Emacs and deliver a fraction of it. JavaScript makes the boundary plain.
- **The manual must say what is absent:** Emacs Lisp functions, packages, advice, minor modes, buffer-local variables, `interactive` codes other than the prompts, per-keystroke hooks and access to other buffers. It should carry a porting table (the right-hand column of the API table above, read the other way).
- **Import from Emacs** (`Sources/OrgApp/EmacsImport.swift`) reads `defun`s only to find bindings. Bindings to the user's own functions should be listed as skipped with a pointer to user commands, instead of being dropped without comment.
- Bindings work as for built-in commands: `command = "user.weekly-review"` in `keymap.toml`, in every preset and Doom state; key hints show the title.

## Options rejected

- **The Emacs Lisp subset as the command language.** Its step and depth limits are the only thing it does better than JavaScript in a worker. Against it: no buffer or Org API (writing one that behaves like Emacs is larger than this whole plan), the expectation problem above, and that most users new to Org don't know Lisp. It keeps its current jobs: formulas, header arguments, diary sexps, capture templates, `elisp:` links and Emacs Lisp blocks.
- **JavaScript in the in-process `JSContext`.** No way to stop a runaway script, its memory counts against the app, and no JIT on iOS. Kept for `js` blocks, whose behaviour must match node's and which already handle abandoned runs.
- **Lua.** Real in-process limits (count hooks, a custom allocator) and fast synchronous calls are its strengths. Against it: a fourth interpreter beside JavaScriptCore, Pyodide and Elisp; a C dependency and a new bridge with no existing code; byte strings whose offsets differ from OrgCore's UTF-16 ones, a constant source of bugs at the API boundary; and fewer users who know it.
- **WebAssembly.** Not something users write; it needs a compiler for another language and a host API to target. No demand.
- **Shortcuts and App Intents as the only route.** Safe and native, but a shortcut can't see the caret or selection, takes seconds to run, can't be bound in `keymap.toml` or on the key bar, and can't express text transforms. Shortcuts remain the route for automation from outside the app (#175, #118).
- **Emacs itself in the download build** (`Sources/OrgPrograms/EmacsRunner.swift` already runs `emacs --batch` for tables and blocks). Full Emacs Lisp, but only on a Mac with Emacs, slow to start, and commands written this way wouldn't run on iOS or in the App Store build.
- **An in-app catalog or install from a URL.** Brings guideline 4.7's obligations and a supply-chain risk for no gain over copying a file.

## Plan

| Phase | Issue | Work | Platforms | Depends on | Effort |
|---|---|---|---|---|---|
| 1 | #244 | Command host: worker in a hidden `WKWebView`, scheme handler serving only `commands/`, CSP and content rule list, globals removed, timeout, cancel, content-process crash handling, measured round trip for 1 MB | Mac (both builds), iOS | — | 1.5–2 days |
| 1 | #245 | `commands.toml` and `commands/`: loading and problems on Mac and iOS, `UserCommand` and `.external(.userCommand)`, registration in palette, `keymap.toml`, iOS Commands and `[key-bar]`, API version 1, trust prompt by file hash, refusal with decrypted entries, Import from Emacs note, manual chapter with a porting table, German strings | Mac (both builds), iOS | #244 | 2.5–3 days |
| 2 | #246 | `org.run(id)` with one undo step per user command; macros record and replay user commands | Mac, iOS | #245 | 1–1.5 days |
| 2 | #247 | `workspace = true`: `org.search`, `org.outlineOf`, agenda entries, `org.capture`; the second trust approval | Mac, iOS | #245 | 1.5–2 days |
| 3 | #248 | Hooks: `after-todo-state-change`, `capture-before-finalize` | Mac, iOS | #245 | 1–1.5 days |

About 7–10 days in all, against milestone 8's earlier estimate of 0.3–0.5× milestone 1, which counted this issue as a review only. Phase 1 is the first public API, which is why 2.0.0 is pencilled for this milestone.

## Questions for the owner

- Whether user commands need orgstar+, as running code blocks does.
- Whether phase 3 is wanted, or waits for requests after phase 1 ships.
- The default timeout (2 s proposed) and the ceiling (30 s).
