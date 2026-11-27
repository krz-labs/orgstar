#if canImport(WebKit)
import Foundation
import OrgCore
import WebKit

/// python blocks in Pyodide (CPython compiled to WebAssembly), for the App Store builds, which
/// can't start `python3`. Pyodide runs in a web worker of a hidden web view; the page and
/// Pyodide's files come from the app through a URL scheme handler. Only the standard library is
/// there: no packages, matplotlib included.
///
/// One worker runs every block. A block without a session gets new globals; a session keeps its
/// own. Imported modules stay loaded until the worker goes: when a run is canceled or times
/// out, since ending the worker is the only way to stop Python, and with the web view, after a
/// minute without a run, or 15 minutes while a session exists.
public enum PythonBlocks {
    /// Pyodide's folder, which the App Store apps set from `OrgMathJax.pyodide`; python blocks
    /// don't run here without it.
    nonisolated(unsafe) public static var folder: URL?

    static let scheme = "orgstar-python"
    /// Where the block's value is written, in Pyodide's own file system.
    static let resultPath = "/tmp/orgstar-result"

    /// Runs `job` when it is a python block, in `directory` or its `:dir`; nil for other
    /// languages. `:python` is ignored.
    @MainActor
    public static func run(_ job: BabelJob, directory: URL, timeout: Duration = .seconds(300)) async throws -> BabelOutput? {
        guard job.language == "python", let folder else { return nil }
        let session: String
        switch job.runner {
        case .process: session = ""
        case .session(let name, _, _): session = name
        case .emacs: return nil
        }
        let dir = job.directory.map { URL(fileURLWithPath: $0, relativeTo: directory).standardizedFileURL } ?? directory
        guard FileManager.default.fileExists(atPath: dir.path) else { throw Babel.Failure.message("No folder \(dir.path) for :dir.") }
        if job.finish.params.contains("graphics") {
            throw Babel.Failure.message(String(localized: "Python blocks can't draw graphics in this version of orgstar: matplotlib isn't included."))
        }
        let source = job.input.replacingOccurrences(of: Babel.resultFileToken, with: resultPath)
        // One namespace per file folder and session name, as `python3` sessions are kept.
        return try await evaluate(source, session: session.isEmpty ? "" : dir.path + "\u{1}" + session, folder: folder, timeout: timeout)
    }

    /// Unloads Pyodide, ending every session.
    @MainActor
    public static func stop() {
        engine?.close()
        engine = nil
    }

    @MainActor private static var engine: Engine?

    @MainActor
    static func evaluate(_ source: String, session: String, folder: URL, timeout: Duration) async throws -> BabelOutput {
        let engine = self.engine ?? Engine(folder: folder)
        self.engine = engine
        engine.idle?.cancel()
        defer { if self.engine === engine { engine.scheduleIdle() } }
        if !session.isEmpty { engine.sessions.insert(session) }
        let run = Run()
        let reply: String
        do {
            reply = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    run.start(continuation, timeout: timeout)
                    Task { @MainActor in
                        do {
                            try await engine.loaded.value
                            let reply = try await engine.webView.callAsyncJavaScript(
                                "return await run({ source, session, result });",
                                arguments: ["source": source, "session": session, "result": resultPath],
                                contentWorld: .page
                            )
                            run.end(.success(reply as? String ?? ""))
                        } catch {
                            run.end(.failure(error))
                        }
                    }
                }
            } onCancel: {
                run.end(.failure(CancellationError()))
            }
        } catch let error as NSError where error.domain == WKErrorDomain {
            if self.engine === engine { stop() }
            guard var message = error.userInfo["WKJavaScriptExceptionMessage"] as? String else {
                throw Babel.Failure.message(String(localized: "Pyodide stopped: \(error.localizedDescription)"))
            }
            while message.hasPrefix("Error: ") { message.removeFirst("Error: ".count) }
            throw Babel.Failure.message("Pyodide: " + message)
        } catch let error where error is CancellationError || error is Babel.Failure {
            // Canceled or timed out: the worker may still be running Python.
            await engine.stopWorker()
            throw error
        } catch {
            if self.engine === engine { stop() }
            throw Babel.Failure.message(String(localized: "Pyodide stopped: \(error.localizedDescription)"))
        }
        guard let parts = try? JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [Any], parts.count == 4,
              let stdout = parts[0] as? String, let stderr = parts[1] as? String, let status = parts[2] as? Int
        else { throw Babel.Failure.message("Pyodide returned nothing.") }
        return BabelOutput(stdout: stdout, resultFile: parts[3] as? String, stderr: stderr, status: Int32(clamping: status))
    }

    /// A run, which ends once: with Python's reply, a cancel or the timeout.
    final class Run: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Result<String, Error>?
        private var continuation: CheckedContinuation<String, Error>?
        private var timer: Task<Void, Never>?

        func start(_ continuation: CheckedContinuation<String, Error>, timeout: Duration) {
            let ended: Result<String, Error>? = lock.withLock {
                if result == nil { self.continuation = continuation }
                return result
            }
            if let ended { return continuation.resume(with: ended) }
            let timer = Task { [weak self] in
                guard (try? await Task.sleep(for: timeout)) != nil else { return }
                self?.end(.failure(Babel.Failure.message("The block took longer than \(timeout) and was stopped.")))
            }
            lock.withLock { self.timer = timer }
        }

        func end(_ outcome: Result<String, Error>) {
            let (waiting, timer) = lock.withLock { () -> (CheckedContinuation<String, Error>?, Task<Void, Never>?) in
                guard result == nil else { return (nil, nil) }
                result = outcome
                defer { continuation = nil; self.timer = nil }
                return (continuation, self.timer)
            }
            timer?.cancel()
            waiting?.resume(with: outcome)
        }
    }

    /// The hidden web view, whose page starts the worker on the first run.
    @MainActor
    final class Engine: NSObject, WKNavigationDelegate {
        let webView: WKWebView
        var sessions: Set<String> = []
        var idle: Task<Void, Never>?
        private(set) var loaded: Task<Void, Error>!
        private var loading: CheckedContinuation<Void, Error>?

        init(folder: URL) {
            let configuration = WKWebViewConfiguration()
            configuration.setURLSchemeHandler(Files(folder: folder), forURLScheme: PythonBlocks.scheme)
            configuration.websiteDataStore = .nonPersistent()
            webView = WKWebView(frame: .zero, configuration: configuration)
            super.init()
            webView.navigationDelegate = self
            loaded = Task {
                try await withCheckedThrowingContinuation { continuation in
                    loading = continuation
                    webView.load(URLRequest(url: URL(string: "\(PythonBlocks.scheme)://pyodide/index.html")!))
                }
            }
        }

        /// Ends the worker, and with it every session.
        func stopWorker() async {
            sessions = []
            _ = try? await webView.callAsyncJavaScript("stop();", contentWorld: .page)
        }

        func scheduleIdle() {
            let wait: Duration = sessions.isEmpty ? .seconds(60) : .seconds(900)
            idle = Task { [weak self] in
                guard (try? await Task.sleep(for: wait)) != nil, let self else { return }
                if PythonBlocks.engine === self { PythonBlocks.stop() }
            }
        }

        func close() {
            idle?.cancel()
            webView.stopLoading()
            webView.navigationDelegate = nil
            finishLoading(.failure(CancellationError()))
        }

        private func finishLoading(_ result: Result<Void, Error>) {
            loading?.resume(with: result)
            loading = nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finishLoading(.success(())) }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finishLoading(.failure(error)) }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finishLoading(.failure(error)) }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            if PythonBlocks.engine === self { PythonBlocks.stop() }
        }
    }

    /// Serves the page, the worker and Pyodide's files, and nothing else.
    @MainActor
    final class Files: NSObject, WKURLSchemeHandler {
        let folder: URL
        static let types: [String: String] = [
            "pyodide.mjs": "text/javascript", "pyodide.asm.mjs": "text/javascript", "pyodide.asm.wasm": "application/wasm",
            "python_stdlib.zip": "application/zip", "pyodide-lock.json": "application/json",
        ]

        init(folder: URL) { self.folder = folder }

        func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
            guard let url = task.request.url, url.host == "pyodide" else { return task.didFailWithError(URLError(.fileDoesNotExist)) }
            let name = url.lastPathComponent
            let file: (Data, String)?
            switch name {
            case "index.html": file = (Data(Self.page.utf8), "text/html")
            case "worker.mjs": file = (Data(Self.worker.utf8), "text/javascript")
            default: file = Self.types[name].flatMap { type in (try? Data(contentsOf: folder.appendingPathComponent(name))).map { ($0, type) } }
            }
            guard let (data, type) = file else { return task.didFailWithError(URLError(.fileDoesNotExist)) }
            task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                            headerFields: ["Content-Type": type, "Content-Length": String(data.count)])!)
            task.didReceive(data)
            task.didFinish()
        }

        func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}

        /// `run` sends a block to the worker, starting it when there is none; `stop` ends it.
        static let page = """
            <!doctype html><meta charset="utf-8"><script>
            let worker = null, next = 0;
            const pending = new Map();
            function fail(message) {
              for (const p of pending.values()) p.reject(new Error(message));
              pending.clear();
            }
            function run(message) {
              if (!worker) {
                worker = new Worker("worker.mjs", { type: "module" });
                worker.onmessage = e => {
                  const p = pending.get(e.data.id);
                  pending.delete(e.data.id);
                  if (e.data.error !== undefined) p.reject(new Error(e.data.error)); else p.resolve(e.data.reply);
                };
                worker.onerror = e => { worker = null; fail(e.message || "Pyodide didn't start."); };
              }
              return new Promise((resolve, reject) => {
                const id = next++;
                pending.set(id, { resolve, reject });
                worker.postMessage({ id, ...message });
              });
            }
            function stop() {
              if (worker) worker.terminate();
              worker = null;
              fail("stopped");
            }
            </script>
            """

        static var worker: String {
            let literal = String(data: try! JSONSerialization.data(withJSONObject: [setup]), encoding: .utf8)!.dropFirst().dropLast()
            return """
                import { loadPyodide } from "./pyodide.mjs";
                const ready = loadPyodide({ indexURL: location.href.replace(/[^/]*$/, ""), stdout: () => {}, stderr: () => {} }).then(pyodide => {
                  pyodide.runPython(\(literal));
                  return pyodide.globals.get("__orgstar_run");
                });
                onmessage = async e => {
                  const { id, source, session, result } = e.data;
                  try {
                    const run = await ready;
                    postMessage({ id, reply: run(source, session, result) });
                  } catch (error) {
                    postMessage({ id, error: String(error && error.message || error) });
                  }
                };
                """
        }

        /// Runs a program as `python3` reads one on standard input, or in a session's
        /// namespace, and returns its output, error output, exit status and value as JSON.
        /// A traceback leaves out this function's frame; in a session an error doesn't change
        /// the status, as the interactive interpreter goes on.
        static let setup = """
            import io, json, os, sys, traceback

            __orgstar_sessions = {}

            def __orgstar_run(source, session, result):
                if session:
                    scope = __orgstar_sessions.setdefault(session, {'__name__': '__main__'})
                else:
                    scope = {'__name__': '__main__'}
                out, err = io.StringIO(), io.StringIO()
                saved = sys.stdin, sys.stdout, sys.stderr
                sys.stdin, sys.stdout, sys.stderr = io.StringIO(), out, err
                status = 0
                try:
                    exec(compile(source, '<org-babel>' if session else '<stdin>', 'exec'), scope)
                except SystemExit as e:
                    if isinstance(e.code, int):
                        status = e.code
                    elif e.code is not None:
                        print(e.code, file=err)
                        status = 1
                except BaseException as e:
                    traceback.print_exception(type(e), e, e.__traceback__.tb_next, file=err)
                    status = 0 if session else 1
                finally:
                    sys.stdin, sys.stdout, sys.stderr = saved
                value = None
                if os.path.exists(result):
                    with open(result) as f:
                        value = f.read()
                    os.remove(result)
                return json.dumps([out.getvalue(), err.getvalue(), status, value])
            """
    }
}
#endif
