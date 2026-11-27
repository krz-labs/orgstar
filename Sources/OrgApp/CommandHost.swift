#if canImport(WebKit)
import Foundation
import WebKit

/// Runs user commands: ES modules in the configuration folder's `commands/`, each run in a new
/// web worker of a hidden web view. Nothing else is reachable from a command. The page, the
/// worker and the modules come from `Files`, which serves only files under `commands/`; every
/// response carries a Content-Security-Policy allowing scripts from this scheme alone; a content
/// rule list blocks every other load; and the worker deletes `fetch`, `XMLHttpRequest` and the
/// other ways out before the command's module loads.
///
/// A worker is started ahead of each run, so a run waits only for its modules; the worker is
/// ended after the run, so no state or module survives into the next. A run that passes its
/// timeout or is canceled ends its worker, which stops it wherever it is. The web view goes after
/// `idle` without a run or `prepare()`, and when its content process ends.
@MainActor
public final class CommandHost {
    public enum Failure: Error, Equatable {
        /// The run passed its time limit and was stopped.
        case timedOut(Duration)
        /// The command threw, or its module or function wasn't found.
        case script(String)
        /// The web view's content process ended, as when a command uses up its memory.
        case stopped
    }

    public static let defaultTimeout: Duration = .seconds(2)
    public static let maximumTimeout: Duration = .seconds(30)
    static let scheme = "orgstar-commands"

    /// The `commands` folder.
    public let folder: URL
    let idle: Duration
    /// Answers a command's call to the app: a name and a JSON value, replying with a JSON value or
    /// throwing to reject the call. Time spent here doesn't count against the run's timeout.
    public var calls: @MainActor (String, Any) async throws -> Any = { name, _ in throw Failure.script("No call \(name).") }

    var engine: Engine?
    private var idleTask: Task<Void, Never>?
    private var next = 0

    public init(folder: URL, idle: Duration = .seconds(300)) {
        self.folder = folder
        self.idle = idle
    }

    isolated deinit {
        idleTask?.cancel()
        engine?.close()
    }

    /// Starts the web view and a worker, if they aren't running, so the next run needn't wait.
    public func prepare() {
        idleTask?.cancel()
        let engine = started()
        Task { [weak self] in
            try? await engine.loaded.value
            _ = try? await engine.webView?.callAsyncJavaScript("prepare();", contentWorld: .page)
            if self?.engine === engine, engine.runs.isEmpty { self?.scheduleIdle() }
        }
    }

    /// Ends the web view; a run in progress fails as `.stopped`.
    public func unload() {
        idleTask?.cancel()
        guard let engine else { return }
        self.engine = nil
        engine.close()
    }

    /// Calls `function` exported by `module`, a path in `commands/`, with the JSON `context` and a
    /// function the command calls the app with, and returns its result as JSON. With `api`, the
    /// function gets that version's `org` object instead, whose calls reach `calls`, and then
    /// `context` unless it is `null`. `timeout` is at most `maximumTimeout`. `answer`, when
    /// given, answers this run's calls in place of `calls`.
    public func run(module: String, function: String, context: String, timeout: Duration = defaultTimeout, api: Int? = nil,
                    answer: (@MainActor (String, Any) async throws -> Any)? = nil) async throws -> String {
        guard Files.relative(module) != nil else { throw Failure.script("No module \(module) in commands/.") }
        let limit = min(timeout, Self.maximumTimeout)
        idleTask?.cancel()
        let engine = started()
        next += 1
        let id = next
        defer { if self.engine === engine, engine.runs.isEmpty { scheduleIdle() } }
        do {
            try await engine.loaded.value
        } catch {
            if self.engine === engine { unload() }
            throw Failure.stopped
        }
        try Task.checkCancellation()
        let run = Run(limit: limit, answer: answer)
        engine.runs[id] = run
        defer { engine.runs[id] = nil }
        let reply: String
        do {
            reply = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    run.start(continuation)
                    Task { @MainActor in
                        do {
                            let reply = try await engine.webView?.callAsyncJavaScript(
                                "return await run(id, module, name, context, api);",
                                arguments: ["id": id, "module": module, "name": function, "context": context, "api": api ?? 0],
                                contentWorld: .page
                            )
                            run.end(.success(reply as? String ?? ""))
                        } catch {
                            run.end(.failure(Failure.stopped))
                        }
                    }
                }
            } onCancel: {
                Task { @MainActor in run.end(.failure(CancellationError())) }
            }
        } catch {
            // Not awaited: a page whose process has stopped answering would never reply.
            engine.webView?.callAsyncJavaScript("stop(id);", arguments: ["id": id], in: nil, in: .page)
            throw error
        }
        guard let object = try? JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any] else { throw Failure.stopped }
        if let result = object["result"] as? String { return result }
        if let message = object["error"] as? String { throw Failure.script(message) }
        throw Failure.stopped
    }

    private func started() -> Engine {
        if let engine { return engine }
        let engine = Engine(folder: folder, host: self)
        self.engine = engine
        return engine
    }

    private func scheduleIdle() {
        idleTask?.cancel()
        idleTask = Task { [weak self, idle] in
            guard (try? await Task.sleep(for: idle)) != nil, let self, self.engine?.runs.isEmpty != false else { return }
            self.unload()
        }
    }

    func terminated(_ engine: Engine) {
        if self.engine === engine { unload() } else { engine.close() }
    }

    func call(_ name: String, _ value: Any, run: Run) async throws -> Any {
        try await (run.answer ?? calls)(name, value)
    }

    /// A run, which ends once: with the worker's reply, a cancel, the timeout or the end of the
    /// web view. The time limit stands still while the app answers a call.
    @MainActor
    final class Run {
        let limit: Duration
        /// Answers this run's calls in place of the host's `calls`.
        let answer: (@MainActor (String, Any) async throws -> Any)?
        private var remaining: Duration
        private var since = ContinuousClock.now
        private var timer: Task<Void, Never>?
        private var calls = 0
        private(set) var ended = false
        private var continuation: CheckedContinuation<String, Error>?

        init(limit: Duration, answer: (@MainActor (String, Any) async throws -> Any)? = nil) {
            self.limit = limit
            self.answer = answer
            remaining = limit
        }

        func start(_ continuation: CheckedContinuation<String, Error>) {
            self.continuation = continuation
            startTimer()
        }

        func end(_ outcome: Result<String, Error>) {
            guard !ended else { return }
            ended = true
            timer?.cancel()
            continuation?.resume(with: outcome)
            continuation = nil
        }

        func pause() {
            calls += 1
            guard calls == 1 else { return }
            timer?.cancel()
            remaining -= ContinuousClock.now - since
        }

        func resume() {
            calls -= 1
            if calls == 0, !ended { startTimer() }
        }

        private func startTimer() {
            since = .now
            timer = Task { [weak self, remaining, limit] in
                guard (try? await Task.sleep(for: remaining)) != nil else { return }
                self?.end(.failure(Failure.timedOut(limit)))
            }
        }
    }

    /// The hidden web view and its page, which keeps one worker ready.
    @MainActor
    final class Engine: NSObject, WKNavigationDelegate, WKScriptMessageHandlerWithReply {
        weak var host: CommandHost?
        private(set) var webView: WKWebView?
        var runs: [Int: Run] = [:]
        private(set) var loaded: Task<Void, Error>!
        private var loading: CheckedContinuation<Void, Error>?
        private var closed = false

        init(folder: URL, host: CommandHost) {
            self.host = host
            super.init()
            loaded = Task { try await start(folder) }
        }

        private func start(_ folder: URL) async throws {
            let rules = try await Engine.rules()
            guard !closed else { throw CancellationError() }
            let configuration = WKWebViewConfiguration()
            configuration.setURLSchemeHandler(Files(folder: folder), forURLScheme: CommandHost.scheme)
            configuration.websiteDataStore = .nonPersistent()
            configuration.userContentController.add(rules)
            configuration.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "commands")
            let webView = WKWebView(frame: .zero, configuration: configuration)
            webView.navigationDelegate = self
            self.webView = webView
            try await withCheckedThrowingContinuation { continuation in
                loading = continuation
                webView.load(URLRequest(url: URL(string: "\(CommandHost.scheme)://host/index.html")!))
            }
        }

        func close() {
            closed = true
            for run in runs.values { run.end(.failure(Failure.stopped)) }
            runs = [:]
            finishLoading(.failure(CancellationError()))
            webView?.stopLoading()
            webView?.navigationDelegate = nil
            webView?.configuration.userContentController.removeAllScriptMessageHandlers()
            webView = nil
        }

        private func finishLoading(_ result: Result<Void, Error>) {
            loading?.resume(with: result)
            loading = nil
        }

        /// Blocks every load but this scheme's, as a second layer under the page's policy.
        static let ruleList = """
            [{"trigger": {"url-filter": ".*"}, "action": {"type": "block"}},
             {"trigger": {"url-filter": "^orgstar-commands://host/"}, "action": {"type": "ignore-previous-rules"}}]
            """
        private static var compiling: Task<WKContentRuleList, Error>?

        static func rules() async throws -> WKContentRuleList {
            let task = compiling ?? Task {
                guard let list = try await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "orgstar-commands", encodedContentRuleList: ruleList)
                else { throw Failure.stopped }
                return list
            }
            compiling = task
            do {
                return try await task.value
            } catch {
                compiling = nil
                throw error
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            decisionHandler(navigationAction.request.url?.scheme == CommandHost.scheme ? .allow : .cancel)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finishLoading(.success(())) }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finishLoading(.failure(error)) }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finishLoading(.failure(error)) }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            host?.terminated(self)
        }

        /// A call from a command, which the page passes on with its run's id.
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) async -> (Any?, String?) {
            guard let body = message.body as? [String: Any], let id = body["run"] as? Int, let name = body["name"] as? String,
                  let run = runs[id], !run.ended, let host
            else { return (nil, "The command was stopped.") }
            run.pause()
            defer { run.resume() }
            do {
                return (try await host.call(name, body["value"] ?? NSNull(), run: run), nil)
            } catch let Failure.script(message) {
                return (nil, message)
            } catch {
                return (nil, error.localizedDescription)
            }
        }
    }

    /// Serves the page and the worker, and the modules in `commands/`, and nothing else.
    @MainActor
    final class Files: NSObject, WKURLSchemeHandler {
        let folder: URL
        static let policy = "default-src 'none'; script-src orgstar-commands:"

        init(folder: URL) { self.folder = folder }

        /// The parts of a path in `commands/`, or nil when it isn't one: a part that is empty, `.`
        /// or `..`, or a file that isn't `.js` or `.mjs`.
        static func relative(_ path: String) -> [Substring]? {
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains(where: { "?#%\\".contains($0) }) }),
                  let last = parts.last, last.hasSuffix(".js") || last.hasSuffix(".mjs")
            else { return nil }
            return parts
        }

        /// The file at `path` in `folder`, once symlinks are resolved, when it is still in `folder`.
        static func file(_ path: String, in folder: URL) -> Data? {
            guard let parts = relative(path),
                  let root = realpath(folder.path, nil).map({ defer { free($0) }; return String(cString: $0) }),
                  let file = realpath(parts.reduce(folder) { $0.appendingPathComponent(String($1)) }.path, nil)
                      .map({ defer { free($0) }; return String(cString: $0) }),
                  file.hasPrefix(root.hasSuffix("/") ? root : root + "/")
            else { return nil }
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: file, isDirectory: &directory), !directory.boolValue else { return nil }
            return FileManager.default.contents(atPath: file)
        }

        func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
            guard let url = task.request.url, url.host == "host" else { return task.didFailWithError(URLError(.fileDoesNotExist)) }
            let path = url.path
            let file: (Data, String)?
            switch path {
            case "/index.html": file = (Data(Self.page.utf8), "text/html")
            case "/host.js": file = (Data(Self.host.utf8), "text/javascript")
            case "/worker.js": file = (Data(Self.worker.utf8), "text/javascript")
            default:
                file = path.hasPrefix("/commands/") ? Self.file(String(path.dropFirst("/commands/".count)), in: folder).map { ($0, "text/javascript") } : nil
            }
            guard let (data, type) = file else { return task.didFailWithError(URLError(.fileDoesNotExist)) }
            task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
                "Content-Type": type, "Content-Length": String(data.count),
                "Content-Security-Policy": Self.policy, "Cache-Control": "no-store",
            ])!)
            task.didReceive(data)
            task.didFinish()
        }

        func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}

        static let page = "<!doctype html><meta charset=\"utf-8\"><script src=\"host.js\"></script>"

        /// `run` gives the ready worker a command and starts the next; the run's result, error or
        /// stop ends its worker. Calls from the worker go to the app with the run's id.
        static let host = """
            "use strict";
            let ready = null;
            const runs = new Map();
            function prepare() {
              if (!ready) ready = new Worker("worker.js", { type: "module" });
            }
            function finish(id, reply) {
              const run = runs.get(id);
              if (!run) return;
              runs.delete(id);
              run.worker.terminate();
              run.resolve(JSON.stringify(reply));
            }
            function run(id, module, name, context, api) {
              prepare();
              const worker = ready;
              ready = null;
              prepare();
              return new Promise(resolve => {
                runs.set(id, { worker, resolve });
                worker.onmessage = async e => {
                  const m = e.data;
                  if (m.kind !== "call") return finish(id, { result: m.result, error: m.error });
                  let reply;
                  try {
                    reply = { seq: m.seq, value: await window.webkit.messageHandlers.commands.postMessage({ run: id, name: m.name, value: m.value }) };
                  } catch (error) {
                    reply = { seq: m.seq, error: String(error && error.message || error) };
                  }
                  if (runs.has(id)) worker.postMessage(reply);
                };
                worker.onerror = e => { e.preventDefault(); finish(id, { error: e.message || "The command didn't start." }); };
                worker.postMessage({ module, name, context, api });
              });
            }
            function stop(id) { finish(id, {}); }
            """

        /// Removes the ways out of the worker, then waits for a command: imports its module, calls
        /// the function with the context and `call`, or for API version 1 with `org` and the
        /// context unless it is null, and posts the result as JSON.
        static let worker = """
            const post = self.postMessage.bind(self);
            for (const name of ["fetch", "XMLHttpRequest", "WebSocket", "EventSource", "importScripts", "indexedDB", "caches", "Worker", "SharedWorker"]) {
              for (let o = self; o; o = Object.getPrototypeOf(o)) delete o[name];
            }
            let calls = 0;
            const waiting = new Map();
            function call(name, value) {
              const seq = calls++;
              return new Promise((resolve, reject) => {
                waiting.set(seq, { resolve, reject });
                post({ kind: "call", seq, name, value });
              });
            }
            function api1() {
              const fail = async text => {
                await call("fail", String(text));
                throw new Error(String(text));
              };
              return Object.freeze({
                version: 1,
                text: () => call("text", null),
                selection: () => call("selection", null),
                heading: at => call("heading", at ?? null),
                outline: () => call("outline", null),
                file: () => call("file", null),
                settings: () => call("settings", null),
                prompt: options => call("prompt", typeof options === "string" ? { message: options } : options ?? {}),
                message: text => call("message", String(text)),
                run: id => call("run", String(id)),
                search: query => call("search", String(query)),
                outlineOf: path => call("outlineOf", String(path)),
                agenda: span => call("agenda", span ?? {}),
                capture: (template, text, fields) => call("capture", { template: String(template), text: text ?? null, fields: fields ?? null }),
                fail,
              });
            }
            self.onmessage = async e => {
              const m = e.data;
              if (m.seq !== undefined) {
                const w = waiting.get(m.seq);
                waiting.delete(m.seq);
                if (w) m.error !== undefined ? w.reject(new Error(m.error)) : w.resolve(m.value);
                return;
              }
              try {
                const module = await import("./commands/" + m.module);
                if (typeof module[m.name] !== "function") throw new Error(`${m.module} exports no function ${m.name}.`);
                const context = JSON.parse(m.context);
                const value = await module[m.name](...(m.api === 1 ? [api1(), ...(context === null ? [] : [context])] : [context, call]));
                post({ result: JSON.stringify(value) ?? "null" });
              } catch (error) {
                post({ error: String(error && error.message || error) });
              }
            };
            """
    }
}
#endif

