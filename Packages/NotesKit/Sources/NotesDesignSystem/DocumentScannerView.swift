import SwiftUI
import UIKit
import VisionKit

/// The system document scanner. Edge detection, perspective correction and
/// multi-page capture all come from VisionKit; we hand back the captured pages as
/// JPEG data so the caller can turn each one into an annotatable page.
///
/// Lives in the design system (not the editor) so both the library's "+ → Scan"
/// entry and the editor's More menu can present it — the editor import rule keeps
/// library code out of `NotesEditor`.
public struct DocumentScannerView: UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss

    /// Called with one JPEG per scanned page, in capture order. Never called with
    /// an empty array — cancelling just dismisses.
    private let onScan: ([Data]) -> Void

    public init(onScan: @escaping ([Data]) -> Void) {
        self.onScan = onScan
    }

    /// False on a device (or simulator) with no camera support for scanning, so
    /// callers can hide the entry point instead of presenting a dead sheet.
    public static var isSupported: Bool {
        VNDocumentCameraViewController.isSupported
    }

    public func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    public func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}

    public func makeCoordinator() -> Coordinator {
        Coordinator(onScan: onScan, onFinish: { dismiss() })
    }

    public final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        private let onScan: ([Data]) -> Void
        private let onFinish: () -> Void

        init(onScan: @escaping ([Data]) -> Void, onFinish: @escaping () -> Void) {
            self.onScan = onScan
            self.onFinish = onFinish
        }

        public func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFinishWith scan: VNDocumentCameraScan
        ) {
            var pages: [Data] = []
            for index in 0..<scan.pageCount {
                if let data = scan.imageOfPage(at: index).jpegData(compressionQuality: 0.85) {
                    pages.append(data)
                }
            }
            if !pages.isEmpty { onScan(pages) }
            onFinish()
        }

        public func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            onFinish()
        }

        public func documentCameraViewController(
            _ controller: VNDocumentCameraViewController, didFailWithError error: Error
        ) {
            onFinish()
        }
    }
}
