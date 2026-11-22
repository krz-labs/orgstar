#if os(iOS)
import SwiftUI
import UIKit
import VisionKit

/// The document camera, for pages to attach; `scanned` gets them as one PDF, or nil when
/// cancelled or failed.
struct DocumentScanner: UIViewControllerRepresentable {
    let scanned: (Data?) -> Void

    static var isAvailable: Bool { VNDocumentCameraViewController.isSupported }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let scanner = VNDocumentCameraViewController()
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: VNDocumentCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(scanned: scanned) }

    /// `pages` as a PDF, each page the size of its image in points.
    nonisolated static func pdf(_ pages: [UIImage]) -> Data {
        UIGraphicsPDFRenderer(bounds: .zero).pdfData { context in
            for page in pages {
                let bounds = CGRect(origin: .zero, size: page.size)
                context.beginPage(withBounds: bounds, pageInfo: [:])
                page.draw(in: bounds)
            }
        }
    }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let scanned: (Data?) -> Void
        init(scanned: @escaping (Data?) -> Void) { self.scanned = scanned }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            let pages = (0..<scan.pageCount).map(scan.imageOfPage(at:))
            scanned(pages.isEmpty ? nil : DocumentScanner.pdf(pages))
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            scanned(nil)
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            scanned(nil)
        }
    }
}
#endif
