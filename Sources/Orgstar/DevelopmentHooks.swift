#if !APPSTORE
import AppKit
import OrgEditorAppKit

/// Switches for checking the app from scripts, read from the environment:
/// - `ORGSTAR_DATA_DIR`: where the index and roots live (see `WorkspaceModel.defaultDirectory`).
/// - `ORGSTAR_OPEN`: a file to select at launch.
/// - `ORGSTAR_ROOT`: a folder to add at launch.
/// - `ORGSTAR_WINDOW`: a window to open at launch (`agenda`, `settings`); the snapshot renders it.
///   `menubar` renders the menu bar item with its menu open instead.
/// - `ORGSTAR_AGENDA_SPAN`: `day`, `week` or `month`, for the agenda window when it opens.
/// - `ORGSTAR_COMMAND`: commands to run at launch, separated by commas (`app.import-emacs`); a
///   sheet or prompt they open is what the snapshot renders.
/// - `ORGSTAR_ANSWERS`: answers to the prompts those commands ask, in order, separated by commas;
///   for Replace in Files and the renames, the two names, then the search runs.
/// - `ORGSTAR_URL`: an `org-protocol://` link to handle at launch, as if opened from a browser.
/// - `ORGSTAR_PASTEBOARD`: the name of a pasteboard to paste images and files from, instead of
///   the clipboard.
/// - `ORGSTAR_APPEARANCE`: `dark` or `light`, instead of the system's.
/// - `ORGSTAR_PRINT_TO`: print jobs are saved to this PDF path without the print panel.
/// - `ORGSTAR_SNAPSHOT`: after `ORGSTAR_SNAPSHOT_DELAY` seconds (default 3), render the main
///   window to this PNG path and quit. Rendering from inside the app needs no screen-recording
///   permission.
///   The clock title key isn't read from the Keychain in such a run.
enum DevelopmentHooks {
    static var fileToOpen: String? { ProcessInfo.processInfo.environment["ORGSTAR_OPEN"] }
    static var rootToAdd: String? { ProcessInfo.processInfo.environment["ORGSTAR_ROOT"] }
    static var windowToOpen: String? { ProcessInfo.processInfo.environment["ORGSTAR_WINDOW"] }
    static var agendaSpan: AgendaSpan? { ProcessInfo.processInfo.environment["ORGSTAR_AGENDA_SPAN"].flatMap(AgendaSpan.init(rawValue:)) }
    static var commandToRun: String? { ProcessInfo.processInfo.environment["ORGSTAR_COMMAND"] }
    static var urlToOpen: String? { ProcessInfo.processInfo.environment["ORGSTAR_URL"] }
    /// `ORGSTAR_SNAPSHOT` is set: the run renders a window and quits.
    static var snapshotting: Bool { ProcessInfo.processInfo.environment["ORGSTAR_SNAPSHOT"] != nil }
    static var printTo: URL? { ProcessInfo.processInfo.environment["ORGSTAR_PRINT_TO"].map { URL(fileURLWithPath: $0) } }
    static var answers: [String] { ProcessInfo.processInfo.environment["ORGSTAR_ANSWERS"]?.split(separator: ",").map(String.init) ?? [] }

    @MainActor
    static func scheduleSnapshot() {
        let environment = ProcessInfo.processInfo.environment
        if let name = environment["ORGSTAR_PASTEBOARD"] { OrgEditor.pasteboard = NSPasteboard(name: NSPasteboard.Name(name)) }
        if let appearance = environment["ORGSTAR_APPEARANCE"] {
            NSApp.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        }
        guard let path = environment["ORGSTAR_SNAPSHOT"] else { return }
        let delay = Double(environment["ORGSTAR_SNAPSHOT_DELAY"] ?? "") ?? 3
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            if windowToOpen == "menubar" { return snapshotMenuBarItem(to: path) }
            let visible = NSApp.windows.filter(\.isVisible)
            let chosen = windowToOpen.flatMap { id in visible.first { $0.identifier?.rawValue.lowercased().contains(id) == true } } ?? visible.first
            let window = chosen?.attachedSheet ?? chosen
            if let window, let image = image(of: window) {
                try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            } else if let view = window?.contentView?.superview,
               let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
            if let chosen, let sheet = chosen.attachedSheet { chosen.endSheet(sheet) }
            NSApp.terminate(nil)
        }
    }

    /// The window server's image of one of the app's own windows, which needs no permission
    /// and, unlike cacheDisplay, draws the sidebar. Swift can't call it directly since macOS 15.
    @MainActor
    private static func image(of window: NSWindow) -> CGImage? {
        typealias Capture = @convention(c) (CGRect, CGWindowListOption, CGWindowID, CGWindowImageOption) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage"),
              let number = CGWindowID(exactly: window.windowNumber) else { return nil }
        return unsafeBitCast(symbol, to: Capture.self)(.null, .optionIncludingWindow, number,
                                                       [.boundsIgnoreFraming, .bestResolution])?.takeRetainedValue()
    }

    /// `ORGSTAR_WINDOW=menubar`: opens the menu bar item's menu and renders the item and the
    /// menu, as they are placed on the screen, into one image.
    @MainActor
    private static func button(in view: NSView) -> NSButton? {
        (view as? NSButton) ?? view.subviews.lazy.compactMap(button(in:)).first
    }

    @MainActor
    private static func snapshotMenuBarItem(to path: String) {
        let bar = NSApp.windows.filter { $0.isVisible && $0.className.contains("StatusBar") }
        guard let button = bar.lazy.compactMap({ $0.contentView.flatMap(button(in:)) }).first else { exit(1) }
        let capture = Timer(timeInterval: 1.5, repeats: false) { _ in
            MainActor.assumeIsolated {
                // The item has a window on each screen's menu bar; the one above the menu.
                let menus = NSApp.windows.filter { $0.isVisible && $0.windowNumber > 0 && $0.className.contains("Menu") }
                let screen = menus.first?.screen?.frame ?? .infinite
                let windows = NSApp.windows.filter { $0.isVisible && $0.windowNumber > 0 && $0.className.contains("StatusBar") && screen.intersects($0.frame) } + menus
                let union = windows.map(\.frame).reduce(CGRect.null) { $0.union($1) }
                let scale = windows.first?.backingScaleFactor ?? 2
                if let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(union.width * scale), pixelsHigh: Int(union.height * scale),
                                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                 bytesPerRow: 0, bitsPerPixel: 0),
                   let context = NSGraphicsContext(bitmapImageRep: bitmap) {
                    NSGraphicsContext.current = context
                    NSColor.windowBackgroundColor.setFill()
                    CGRect(x: 0, y: 0, width: union.width * scale, height: union.height * scale).fill()
                    func draw(_ image: CGImage, at frame: CGRect) {
                        let frame = frame.offsetBy(dx: -union.minX, dy: -union.minY)
                        context.cgContext.draw(image, in: CGRect(x: frame.minX * scale, y: frame.minY * scale, width: frame.width * scale, height: frame.height * scale))
                    }
                    for window in windows {
                        // The window server leaves the menu bar's windows blank; the button draws itself.
                        if window.className.contains("StatusBar"), let view = window.contentView.flatMap(button(in:)),
                           let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                            view.cacheDisplay(in: view.bounds, to: bitmap)
                            if let image = bitmap.cgImage { draw(image, at: window.convertToScreen(view.convert(view.bounds, to: nil))) }
                        } else if let image = image(of: window) {
                            draw(image, at: window.frame)
                        }
                    }
                    try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                }
                // Menu tracking holds the run loop, so the app ends here.
                exit(0)
            }
        }
        RunLoop.main.add(capture, forMode: .common)
        button.performClick(nil)
    }
}
#endif
