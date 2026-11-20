import GrafttyProtocol
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Shared clipboard handling and attachment previews for the worktree sheets.
public struct WorktreePromptImages<Editor: View>: View {
    @Binding private var images: [Data]
    @Binding private var isLoading: Bool
    @State private var error: String?
    @State private var pasteTask: Task<Void, Never>?
    private let editor: Editor

    public init(images: Binding<[Data]>, isLoading: Binding<Bool>, @ViewBuilder editor: () -> Editor) {
        _images = images
        _isLoading = isLoading
        self.editor = editor()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            pasteAwareEditor
            if !images.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(images.indices, id: \.self) { index in
                            preview(images[index], index: index)
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
            HStack {
                PasteButton(supportedContentTypes: [.image], payloadAction: paste)
                    .controlSize(.small)
                    .accessibilityLabel("Paste images")
                    .disabled(isLoading || images.count >= WorktreeAgentConfiguration.maximumPromptImageCount)
                if isLoading { ProgressView().controlSize(.small).accessibilityLabel("Preparing images") }
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .onDisappear { pasteTask?.cancel() }
    }

    @ViewBuilder private var pasteAwareEditor: some View {
        #if os(macOS)
        editor.onPasteCommand(of: [.image], perform: paste)
        #else
        editor
        #endif
    }

    private func preview(_ data: Data, index: Int) -> some View {
        ZStack(alignment: .topTrailing) {
            if let image = Self.thumbnail(from: data, maximumPixelSize: 144) {
                Image(decorative: image, scale: 1)
                    .resizable().scaledToFit().frame(width: 72, height: 56)
                    .accessibilityHidden(true)
            }
            Button {
                images.remove(at: index)
                error = nil
            } label: {
                Image(systemName: "xmark.circle.fill").symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove image \(index + 1)")
            .disabled(isLoading)
        }
    }

    private func paste(_ providers: [NSItemProvider]) {
        guard !isLoading, !providers.isEmpty else { return }
        guard providers.count <= WorktreeAgentConfiguration.maximumPromptImageCount - images.count else {
            error = "Attach up to \(WorktreeAgentConfiguration.maximumPromptImageCount) images."
            return
        }
        error = nil
        isLoading = true
        pasteTask = Task { @MainActor in
            defer { isLoading = false }
            var proposedImages = images
            for provider in providers {
                let image = await Self.png(from: provider)
                guard !Task.isCancelled else { return }
                guard let image else {
                    error = "A clipboard image could not be prepared."
                    return
                }
                proposedImages.append(image)
                if let sizeError = WorktreeAgentConfiguration.promptImageSizeError(proposedImages) {
                    error = sizeError
                    return
                }
            }
            images = proposedImages
        }
    }

    private static func png(from provider: NSItemProvider) async -> Data? {
        let types = provider.registeredContentTypes
        guard let type = types.first(where: { $0 == .png }) ?? types.first(where: { $0.conforms(to: .image) }) else {
            return nil
        }
        return await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                continuation.resume(returning: data.flatMap { Self.normalizedPNG($0) })
            }
        }
    }

    nonisolated private static func normalizedPNG(_ data: Data) -> Data? {
        guard let image = thumbnail(from: data, maximumPixelSize: 3072),
              let output = CFDataCreateMutable(nil, 0),
              let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }

    nonisolated private static func thumbnail(from data: Data, maximumPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
        ] as CFDictionary)
    }
}
