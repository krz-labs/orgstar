import Foundation
import OrgCore
#if canImport(QuickLookUI)
import QuickLookUI
#else
import QuickLook
#endif

/// Quick Look's preview of an org file: the file as the HTML export renders it.
@objc(PreviewProvider)
final class PreviewProvider: QLPreviewProvider, QLPreviewingController {
    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        // Latin-1 maps every byte, so a file that isn't UTF-8 still shows.
        let data = try Data(contentsOf: request.fileURL)
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        let title = request.fileURL.deletingPathExtension().lastPathComponent
        let html = HTMLExport.page(text, fallbackTitle: title, settings: OrgSettings.default.resolvingSetupFiles(in: text, path: request.fileURL.path, read: OrgSettings.readFile), path: request.fileURL.path)
        return QLPreviewReply(dataOfContentType: .html, contentSize: CGSize(width: 800, height: 800)) { _ in Data(html.utf8) }
    }
}
