import AppKit

struct WorktreeMapRow: Equatable, Sendable {
    let path: String
    let name: String
    var height: Double
    let context: String?
    var isConnector = false
    var regionID: Int? = nil
}

enum WorktreeMapLayout {
    static let width: CGFloat = 320
    static let landmarkHeight: CGFloat = 80
    static let headerHeight: Double = 128
    static func headerPath(repo: String) -> String { "graftty-map-header:\(repo)" }
    static func footerPath(repo: String) -> String { "graftty-map-footer:\(repo)" }
    static func footer(project: ProjectArtworkSource) -> WorktreeArtworkRequest {
        .init(path: footerPath(repo: project.path), name: "Repeating terrain below the worktrees",
              firstPaneSessionName: nil, project: project, mapHeight: 96, mapFolder: true)
    }
    static func header(project: ProjectArtworkSource) -> WorktreeArtworkRequest {
        .init(path: headerPath(repo: project.path), name: "Project canopy above the worktrees",
              firstPaneSessionName: nil, project: project, mapHeight: headerHeight, mapFolder: true)
    }
    static func height(_ value: Double) -> Double { min(800, max(44, ceil(value))) }
    static func folderPath(repo: String, folder: String) -> String { "graftty-map-folder:\(repo.count):\(repo):\(folder)" }
}

@MainActor
enum WorktreeMapRaster {
    static func hasCompleteCanvas(_ image: NSImage) -> Bool {
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil),
              let context = CGContext(data: nil, width: 32, height: 64, bitsPerComponent: 8,
                bytesPerRow: 128, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let bytes = context.data?.assumingMemoryBound(to: UInt8.self) else { return false }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: 32, height: 64))
        let painted = (0..<(32 * 64)).filter { bytes[$0 * 4 + 3] >= 250 }.count
        return painted >= 32 * 64 * 99 / 100
    }

    static func compose(rows: [WorktreeMapRow], generated: NSImage?, preserving: [String: NSImage],
                        regionTerrain: [String: NSImage] = [:]) throws -> NSImage {
        let height = rows.reduce(0) { $0 + $1.height }
        return try draw(size: .init(width: WorktreeMapLayout.width, height: height)) { ctx in
            if let generated { paint(generated, in: CGRect(x: 0, y: 0, width: WorktreeMapLayout.width, height: height), context: ctx) }
            var top: CGFloat = 0
            for row in rows {
                defer { top += row.height }
                if let terrain = regionTerrain[row.path] {
                    paint(terrain, in: CGRect(x: 0, y: top, width: WorktreeMapLayout.width, height: row.height), context: ctx)
                }
                guard let original = preserving[row.path] else { continue }
                let h = min(original.size.height, row.height)
                let rect = CGRect(x: 0, y: top, width: original.size.width, height: original.size.height)
                // Only the twelve-point transition at each edge can change.
                // The interior is copied from the original, never model-redrawn.
                for y in stride(from: CGFloat(0), to: h, by: 1) {
                    let alpha = min(1, min(y / 12, (h - 1 - y) / 12))
                    ctx.saveGState()
                    ctx.clip(to: CGRect(x: 0, y: top + y, width: WorktreeMapLayout.width, height: 1))
                    ctx.setAlpha(alpha)
                    paint(original, in: rect, context: ctx)
                    ctx.restoreGState()
                }
            }
        }
    }

    static func slices(_ image: NSImage, rows: [WorktreeMapRow]) throws -> [String: NSImage] {
        var top: CGFloat = 0
        var result: [String: NSImage] = [:]
        for row in rows {
            let offset = top
            result[row.path] = try draw(size: .init(width: WorktreeMapLayout.width, height: row.height)) { ctx in
                paint(image, in: CGRect(x: 0, y: -offset, width: image.size.width, height: image.size.height), context: ctx)
            }
            top += row.height
        }
        return result
    }

    static func png(_ image: NSImage) throws -> Data {
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil),
              let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else {
            throw ImageCreatorWorktreeIcon.Failure.invalidImage
        }
        return data
    }

    static func draw(size: CGSize, body: (CGContext) -> Void) throws -> NSImage {
        guard size.width > 0, size.height > 0, size.height <= 32000,
              let context = CGContext(data: nil, width: Int(size.width * 2), height: Int(size.height * 2),
                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ImageCreatorWorktreeIcon.Failure.invalidImage
        }
        context.translateBy(x: 0, y: size.height * 2)
        context.scaleBy(x: 2, y: -2)
        context.interpolationQuality = .high
        body(context)
        guard let cg = context.makeImage() else { throw ImageCreatorWorktreeIcon.Failure.invalidImage }
        return NSImage(cgImage: cg, size: size)
    }

    private static func paint(_ image: NSImage, in rect: CGRect, context: CGContext) {
        var source = CGRect(origin: .zero, size: image.size)
        guard let cg = image.cgImage(forProposedRect: &source, context: nil, hints: nil) else { return }
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(cg, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }
}
