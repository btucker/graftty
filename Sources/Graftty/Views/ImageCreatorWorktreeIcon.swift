import AppKit
import ImagePlayground

/// Keep the experimental ImageCreator dependency separate from scheduling and storage.
enum ImageCreatorWorktreeIcon {
    enum Failure: LocalizedError {
        case unavailable
        case invalidImage

        var errorDescription: String? {
            switch self {
            case .unavailable: return "Image generation is unavailable on this Mac."
            case .invalidImage: return "ImageCreator returned an unreadable image."
            }
        }
    }

    @MainActor
    static func generate(name: String, userContext: String, style: WorktreeArtworkStyle, variation: UInt64 = 0, theme: WorktreeArtworkTheme? = nil, project: ProjectArtworkDirection? = nil) async throws -> Data {
        guard #available(macOS 15.4, *), ImagePlaygroundViewController.isAvailable else {
            throw Failure.unavailable
        }
        let identity = try await WorktreeArtworkPrompt.identity(for: name, userContext: userContext, variation: variation, theme: theme, project: project)
        let creator: ImageCreator
        do {
            creator = try await ImageCreator()
        } catch ImageCreator.Error.notSupported {
            throw Failure.unavailable
        } catch ImageCreator.Error.unavailable {
            throw Failure.unavailable
        }
        let preferred: ImagePlaygroundStyle
        switch style {
        case .illustration: preferred = .illustration
        case .animation: preferred = .animation
        case .sketch: preferred = .sketch
        }
        let style = creator.availableStyles.first { $0 == preferred }
            ?? creator.availableStyles.first
        guard let style else { throw Failure.unavailable }
        return try await generate(identity: identity) { descriptions in
            let concepts = descriptions.map { ImagePlaygroundConcept.text($0) }
            for try await result in creator.images(for: concepts, style: style, limit: 1) {
                try Task.checkCancellation()
                return try thumbnailData(from: result.cgImage)
            }
            throw ImageCreator.Error.creationFailed
        }
    }

    @available(macOS 15.4, *)
    @MainActor
    static func generate(
        identity: WorktreeArtworkIdentity,
        render: ([String]) async throws -> Data
    ) async throws -> Data {
        do {
            return try await render(identity.concepts)
        } catch {
            try Task.checkCancellation()
            guard let creationError = error as? ImageCreator.Error else { throw error }
            var canRetry = creationError == .unsupportedLanguage || creationError == .creationFailed
            if #available(macOS 26.0, *), creationError == .conceptsRequirePersonIdentity { canRetry = true }
            guard canRetry else { throw error }
            return try await render(identity.fallbackConcepts)
        }
    }

    static func thumbnailData(from image: CGImage) throws -> Data {
        // Preserve enough detail for a sidebar block without caching the full source.
        let scale = min(1, 512.0 / Double(max(image.width, image.height)))
        let width = max(1, Int(Double(image.width) * scale))
        let height = max(1, Int(Double(image.height) * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw Failure.invalidImage
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let thumbnail = context.makeImage(),
              let data = NSBitmapImageRep(cgImage: thumbnail).representation(using: .png, properties: [:]) else {
            throw Failure.invalidImage
        }
        return data
    }
}
