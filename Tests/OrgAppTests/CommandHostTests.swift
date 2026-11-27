import Foundation
import Network
import Testing
import WebKit
@testable import OrgApp

/// A local port that counts the connections made to it, to show a load never left the web view.
final class Listener: @unchecked Sendable {
    private let listener: NWListener
    private let counter = Counter()
    let port: UInt16
    var connections: Int { counter.value }
    var url: String { "http://127.0.0.1:\(port)/" }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.withLock { count } }
        func add() { lock.withLock { count += 1 } }
    }

    init() async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let counter = counter
        listener.newConnectionHandler = { connection in
            counter.add()
            connection.cancel()
        }
        let ready = AsyncStream<UInt16> { continuation in
            listener.stateUpdateHandler = { state in
                if case .ready = state { continuation.yield(listener.port?.rawValue ?? 0); continuation.finish() }
            }
        }
        listener.start(queue: .global())
        var port: UInt16 = 0
        for await value in ready { port = value }
        self.listener = listener
        self.port = port
    }

    deinit { listener.cancel() }
}

@MainActor
@Suite(.serialized)
struct CommandHostTests {
    let folder: Folder
    let host: CommandHost

    init() throws {
        folder = try Folder()
        host = CommandHost(folder: folder.url.appendingPathComponent("commands"))
        try folder.write("commands/util.js", "export const twice = s => s + s;\n")
        try folder.write("commands/main.js", """
            import { twice } from "./util.js";
            export function echo(context) { return context; }
            export async function double(context) { return { text: twice(context.text) }; }
            export function nothing() {}
            export function fails() { throw new Error("no heading here"); }
            export function loop() { for (;;) {} }
            export function counter() { globalThis.count = (globalThis.count ?? 0) + 1; return globalThis.count; }
            export async function ask(context, call) { return [await call("prompt", context), await call("message", "hi")]; }
            export async function refused(context, call) {
              try { await call("nope", null); } catch (e) { return "caught " + e.message; }
            }
            export async function waits(context, call) { await call("wait", null); return "done"; }
            """)
    }

    @Test func runsAnExportedFunction() async throws {
        #expect(try await host.run(module: "main.js", function: "double", context: #"{"text": "ab"}"#) == #"{"text":"abab"}"#)
        #expect(try await host.run(module: "main.js", function: "echo", context: #"[1, "é", null]"#) == #"[1,"é",null]"#)
        #expect(try await host.run(module: "main.js", function: "nothing", context: "{}") == "null")
        await #expect(throws: CommandHost.Failure.script("no heading here")) {
            _ = try await host.run(module: "main.js", function: "fails", context: "{}")
        }
        await #expect(throws: CommandHost.Failure.script("main.js exports no function absent.")) {
            _ = try await host.run(module: "main.js", function: "absent", context: "{}")
        }
        await #expect(throws: CommandHost.Failure.script("No module ../main.js in commands/.")) {
            _ = try await host.run(module: "../main.js", function: "echo", context: "{}")
        }
    }

    /// Each run has a new worker: nothing a command leaves in the global scope reaches the next,
    /// and a changed file is read again.
    @Test func runsDontShareState() async throws {
        #expect(try await host.run(module: "main.js", function: "counter", context: "{}") == "1")
        #expect(try await host.run(module: "main.js", function: "counter", context: "{}") == "1")
        try folder.write("commands/util.js", "export const twice = s => s + s + s;\n")
        #expect(try await host.run(module: "main.js", function: "double", context: #"{"text": "a"}"#) == #"{"text":"aaa"}"#)
    }

    @Test func callsTheApp() async throws {
        var seen: [String] = []
        host.calls = { name, value in
            seen.append(name)
            switch name {
            case "prompt": return "answer to \((value as? [String: Any])?["message"] ?? "")"
            case "message": return NSNull()
            default: throw CommandHost.Failure.script("No call \(name).")
            }
        }
        #expect(try await host.run(module: "main.js", function: "ask", context: #"{"message": "Week"}"#) == #"["answer to Week",null]"#)
        #expect(seen == ["prompt", "message"])
        #expect(try await host.run(module: "main.js", function: "refused", context: "{}") == #""caught No call nope.""#)
    }

    /// Time the app spends answering a call, as in a prompt, isn't counted.
    @Test func timeInACallDoesntCount() async throws {
        host.calls = { _, _ in
            try await Task.sleep(for: .milliseconds(1500))
            return NSNull()
        }
        #expect(try await host.run(module: "main.js", function: "waits", context: "{}", timeout: .seconds(1)) == #""done""#)
    }

    @Test func stopsAnEndlessLoopAndRunsAgain() async throws {
        let start = ContinuousClock.now
        await #expect(throws: CommandHost.Failure.timedOut(.seconds(1))) {
            _ = try await host.run(module: "main.js", function: "loop", context: "{}", timeout: .seconds(1))
        }
        #expect(try await host.run(module: "main.js", function: "echo", context: "7") == "7")
        // The same web view: only the worker was ended.
        #expect(host.engine != nil)
        #expect(ContinuousClock.now - start < .seconds(10))
    }

    @Test func cancels() async throws {
        let task = Task { try await host.run(module: "main.js", function: "loop", context: "{}", timeout: .seconds(30)) }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(try await host.run(module: "main.js", function: "echo", context: "8") == "8")
    }

    @Test func importsOnlyFromTheCommandsFolder() async throws {
        try folder.write("outside.js", "export const secret = 1;\n")
        try folder.write("commands/escape.js", """
            export async function parent() { return (await import("../outside.js")).secret; }
            export async function absolute() { return (await import("/outside.js")).secret; }
            export async function file(path) { return (await import("file://" + path)).secret; }
            export async function data() { return (await import("data:text/javascript,export const secret = 1")).secret; }
            """)
        for function in ["parent", "absolute", "data"] {
            await #expect(throws: CommandHost.Failure.self, "\(function)") {
                _ = try await host.run(module: "escape.js", function: function, context: "{}")
            }
        }
        await #expect(throws: CommandHost.Failure.self) {
            _ = try await host.run(module: "escape.js", function: "file", context: "\"\(folder.url.appendingPathComponent("outside.js").path)\"")
        }
    }

    @Test func refusesSymlinksOutOfTheCommandsFolder() async throws {
        try folder.write("secret.js", "export function echo(c) { return c; }\n")
        try folder.write("lib/inner.js", "export function echo(c) { return c; }\n")
        let commands = folder.url.appendingPathComponent("commands")
        try FileManager.default.createSymbolicLink(atPath: commands.appendingPathComponent("link.js").path, withDestinationPath: "../secret.js")
        try FileManager.default.createSymbolicLink(atPath: commands.appendingPathComponent("lib").path, withDestinationPath: folder.url.appendingPathComponent("lib").path)
        try FileManager.default.createSymbolicLink(atPath: commands.appendingPathComponent("same.js").path, withDestinationPath: "main.js")
        await #expect(throws: CommandHost.Failure.self) { _ = try await host.run(module: "link.js", function: "echo", context: "1") }
        await #expect(throws: CommandHost.Failure.self) { _ = try await host.run(module: "lib/inner.js", function: "echo", context: "1") }
        #expect(try await host.run(module: "same.js", function: "echo", context: "1") == "1")
        #expect(CommandHost.Files.file("link.js", in: commands) == nil)
        #expect(CommandHost.Files.file("lib/inner.js", in: commands) == nil)
        #expect(CommandHost.Files.file("main.js", in: commands) != nil)
        #expect(CommandHost.Files.file("../secret.js", in: commands) == nil)
        #expect(CommandHost.Files.file("util.txt", in: commands) == nil)
    }

    /// The worker has none of the ways out, and nothing reaches a local port: not from a command,
    /// not from a worker with its globals intact, not from the page.
    @Test func reachesNoNetwork() async throws {
        let listener = try await Listener()
        try folder.write("commands/net.js", """
            export function globals() {
              return ["fetch", "XMLHttpRequest", "WebSocket", "EventSource", "importScripts", "indexedDB", "caches", "Worker"].filter(n => n in self);
            }
            export async function load(url) { return (await import(url)).x; }
            export async function fetched(url) { return await fetch(url); }
            export async function requested(url) { const r = new XMLHttpRequest(); r.open("GET", url, false); r.send(); }
            export async function socket(url) { new WebSocket(url.replace("http", "ws")); }
            """)
        try folder.write("commands/probe.js", """
            const url = "\(listener.url)";
            const tries = [
              () => fetch(url, { mode: "no-cors" }),
              () => { const r = new XMLHttpRequest(); r.open("GET", url, false); r.send(); },
              () => new WebSocket(url.replace("http", "ws")),
              () => new EventSource(url),
              () => import(url + "x.js"),
            ];
            Promise.allSettled(tries.map(t => { try { return Promise.resolve(t()); } catch (e) { return Promise.reject(e); } }))
              .then(r => postMessage(r.map(x => x.status)));
            """)
        #expect(try await host.run(module: "net.js", function: "globals", context: "{}") == "[]")
        for function in ["load", "fetched", "requested", "socket"] {
            await #expect(throws: CommandHost.Failure.self, "\(function)") {
                _ = try await host.run(module: "net.js", function: function, context: "\"\(listener.url)x.js\"")
            }
        }
        let webView = try #require(host.engine?.webView)
        let probed = try await webView.callAsyncJavaScript("""
            const w = new Worker("commands/probe.js", { type: "module" });
            return await new Promise(r => { w.onmessage = e => r(e.data); w.onerror = e => r(["error", e.message]); });
            """, contentWorld: .page)
        print("A worker with its globals: \(probed ?? "nothing")")
        _ = try? await webView.callAsyncJavaScript("await fetch(url, { mode: 'no-cors' });", arguments: ["url": listener.url], contentWorld: .page)
        _ = try? await webView.callAsyncJavaScript("await fetch(url, { mode: 'no-cors' });", arguments: ["url": listener.url], contentWorld: .defaultClient)
        try await Task.sleep(for: .milliseconds(500))
        #expect(listener.connections == 0)
    }

    /// The content rule list alone blocks a load the same web view makes without it.
    @Test func ruleListBlocksOtherLoads() async throws {
        let listener = try await Listener()
        func connects(_ rules: WKContentRuleList?) async throws -> Bool {
            let before = listener.connections
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            if let rules { configuration.userContentController.add(rules) }
            let webView = WKWebView(frame: .zero, configuration: configuration)
            _ = try? await webView.callAsyncJavaScript("await fetch(url, { mode: 'no-cors' });", arguments: ["url": listener.url], contentWorld: .page)
            try await Task.sleep(for: .milliseconds(300))
            return listener.connections > before
        }
        #expect(try await connects(nil))
        #expect(try await !connects(CommandHost.Engine.rules()))
    }

    @Test func recoversWhenTheContentProcessEnds() async throws {
        #expect(try await host.run(module: "main.js", function: "echo", context: "1") == "1")
        let webView = try #require(host.engine?.webView)
        // Ended from outside, as the system ends a process that runs out of memory.
        let pid = try #require(webView.value(forKey: "_webProcessIdentifier") as? Int32)
        try #require(pid > 0)
        let task = Task { try await host.run(module: "main.js", function: "loop", context: "{}", timeout: .seconds(10)) }
        try await Task.sleep(for: .milliseconds(300))
        kill(pid, SIGKILL)
        await #expect(throws: CommandHost.Failure.stopped) { _ = try await task.value }
        #expect(host.engine == nil)
        #expect(try await host.run(module: "main.js", function: "echo", context: "2") == "2")
    }

    @Test func unloadsWhenIdle() async throws {
        let host = CommandHost(folder: folder.url.appendingPathComponent("commands"), idle: .milliseconds(200))
        #expect(try await host.run(module: "main.js", function: "echo", context: "1") == "1")
        #expect(host.engine != nil)
        try await Task.sleep(for: .seconds(1))
        #expect(host.engine == nil)
    }

    /// Prints first start, a warm round trip and a round trip carrying 1 MB each way.
    @Test func measures() async throws {
        host.unload()
        var start = ContinuousClock.now
        _ = try await host.run(module: "main.js", function: "echo", context: "1")
        let first = ContinuousClock.now - start
        func median(_ times: Int, _ body: () async throws -> Void) async rethrows -> Duration {
            var all: [Duration] = []
            for _ in 0..<times {
                start = .now
                try await body()
                all.append(ContinuousClock.now - start)
                try? await Task.sleep(for: .milliseconds(50))
            }
            return all.sorted()[times / 2]
        }
        let warm = try await median(21) { _ = try await host.run(module: "main.js", function: "echo", context: "1") }
        let megabyte = String(repeating: "* Heading\nSome text é\n", count: 1_048_576 / 23)
        let context = String(data: try JSONSerialization.data(withJSONObject: ["text": megabyte]), encoding: .utf8)!
        let large = try await median(9) {
            let reply = try await host.run(module: "main.js", function: "echo", context: context)
            #expect(reply.count == context.count)
        }
        print("Command host: first start \(first), warm round trip \(warm), 1 MB round trip \(large)")
    }
}

