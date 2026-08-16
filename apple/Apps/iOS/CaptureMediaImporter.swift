import Foundation
import OdysseyApplication
import OdysseyDomain
import Photos
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct PreparedCaptureMediaSelection: Hashable, Sendable {
    let preparedImport: LocalCapturePreparedImport
    let kind: CapturePayloadKind
    let mediaType: String
}

enum CaptureMediaImportOutcome: Sendable {
    case selected(PreparedCaptureMediaSelection)
    case cancelled
    case failed(String)
}

enum CaptureMediaImportPreparer {
    static func prepare(
        sourceURL: URL,
        kind: CapturePayloadKind,
        declaredTypeIdentifier: String? = nil,
        importBuffer: LocalCaptureImportBuffer
    ) -> CaptureMediaImportOutcome {
        guard kind == .imageReference || kind == .fileReference else {
            return .failed("Only a selected photo or file can be imported here.")
        }
        let accessedSecurityScope = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessedSecurityScope {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }
        let extensionType = UTType(filenameExtension: sourceURL.pathExtension)
        let declaredType = declaredTypeIdentifier.flatMap { UTType($0) }
        let resourceType = try? sourceURL.resourceValues(
            forKeys: [.contentTypeKey]
        ).contentType
        let contentType: UTType?
        if kind == .imageReference {
            contentType = [extensionType, resourceType, declaredType]
                .compactMap { $0 }
                .first { $0.conforms(to: .image) }
        } else {
            contentType = extensionType ?? resourceType ?? declaredType
        }
        if kind == .imageReference,
           contentType?.conforms(to: .image) != true
        {
            return .failed("The selected photo format is not supported.")
        }
        let mediaType: String
        if let preferredMIMEType = contentType?.preferredMIMEType?.lowercased() {
            mediaType = preferredMIMEType
        } else if kind == .fileReference {
            mediaType = "application/octet-stream"
        } else {
            return .failed("The selected photo format has no supported media type.")
        }
        do {
            return .selected(PreparedCaptureMediaSelection(
                preparedImport: try importBuffer.prepareFile(at: sourceURL),
                kind: kind,
                mediaType: mediaType
            ))
        } catch let error as LocalizedError {
            return .failed(
                error.errorDescription
                    ?? "The selected item could not be prepared safely."
            )
        } catch {
            return .failed("The selected item could not be prepared safely.")
        }
    }
}

struct PhotoCapturePicker: UIViewControllerRepresentable {
    let importBuffer: LocalCaptureImportBuffer
    let requestID: UUID
    let onCompletion: @MainActor @Sendable (UUID, CaptureMediaImportOutcome) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            importBuffer: importBuffer,
            requestID: requestID,
            onCompletion: onCompletion
        )
    }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .images
        configuration.selectionLimit = 1
        configuration.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_: PHPickerViewController, context _: Context) {}

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        private let importBuffer: LocalCaptureImportBuffer
        private let requestID: UUID
        private let onCompletion: @MainActor @Sendable (
            UUID,
            CaptureMediaImportOutcome
        ) -> Void

        init(
            importBuffer: LocalCaptureImportBuffer,
            requestID: UUID,
            onCompletion: @escaping @MainActor @Sendable (
                UUID,
                CaptureMediaImportOutcome
            ) -> Void
        ) {
            self.importBuffer = importBuffer
            self.requestID = requestID
            self.onCompletion = onCompletion
        }

        func picker(
            _: PHPickerViewController,
            didFinishPicking results: [PHPickerResult]
        ) {
            guard let provider = results.first?.itemProvider else {
                complete(with: .cancelled)
                return
            }
            let imageTypeIdentifiers = provider.registeredTypeIdentifiers.filter {
                UTType($0)?.conforms(to: .image) == true
            }
            guard let typeIdentifier = imageTypeIdentifiers.first(where: {
                UTType($0)?.preferredMIMEType != nil
            }) ?? imageTypeIdentifiers.first else {
                complete(with: .failed("The selected photo format is not supported."))
                return
            }
            let importBuffer = importBuffer
            let requestID = requestID
            let onCompletion = onCompletion
            provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, _ in
                let outcome: CaptureMediaImportOutcome
                if let url {
                    outcome = CaptureMediaImportPreparer.prepare(
                        sourceURL: url,
                        kind: .imageReference,
                        declaredTypeIdentifier: typeIdentifier,
                        importBuffer: importBuffer
                    )
                } else {
                    outcome = .failed("The selected photo could not be read safely.")
                }
                Task { @MainActor in
                    onCompletion(requestID, outcome)
                }
            }
        }

        private func complete(with outcome: CaptureMediaImportOutcome) {
            let requestID = requestID
            let onCompletion = onCompletion
            Task { @MainActor in
                onCompletion(requestID, outcome)
            }
        }
    }
}
