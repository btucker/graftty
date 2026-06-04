import SwiftUI
import GrafttyKit

/// Maps a repo's hosting origin to its sidebar presentation: which
/// forge mark to draw and the user-facing forge name. nil for
/// unsupported providers and absent origins, which render with no
/// icon at all (PROJECT-2.2).
struct ForgePresentation: Equatable {
    enum Mark: Equatable {
        case github
        case gitlab

        /// Vendored vector geometry, drawn in code rather than
        /// bundled as image assets: SF Symbols has no brand marks,
        /// and this project has shipped broken releases from
        /// resource-bundling gaps (v0.1.5, v0.1.10).
        var pathData: String {
            switch self {
            case .github:
                // Octicons `mark-github` (16x16), MIT licensed.
                return "M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27s1.36.09 2 .27c1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.013 8.013 0 0 0 16 8c0-4.42-3.58-8-8-8z"
            case .gitlab:
                // Simple Icons `gitlab` (24x24), CC0.
                return "m23.6004 9.5927-.0337-.0862L20.3.9814a.851.851 0 0 0-.3362-.405.8748.8748 0 0 0-.9997.0539.8748.8748 0 0 0-.29.4399l-2.2055 6.748H7.5375l-2.2057-6.748a.8573.8573 0 0 0-.29-.4412.8748.8748 0 0 0-.9997-.0537.8585.8585 0 0 0-.3362.4049L.4332 9.5015l-.0325.0862a6.0657 6.0657 0 0 0 2.0119 7.0105l.0113.0087.03.0213 4.976 3.7264 2.462 1.8633 1.4995 1.1321a1.0085 1.0085 0 0 0 1.2197 0l1.4995-1.1321 2.4619-1.8633 5.006-3.7489.0125-.01a6.0682 6.0682 0 0 0 2.0094-7.003z"
            }
        }

        var viewBox: CGSize {
            switch self {
            case .github: return CGSize(width: 16, height: 16)
            case .gitlab: return CGSize(width: 24, height: 24)
            }
        }
    }

    let mark: Mark
    let forgeName: String

    init?(origin: HostingOrigin?) {
        switch origin?.provider {
        case .github:
            mark = .github
            forgeName = "GitHub"
        case .gitlab:
            mark = .gitlab
            forgeName = "GitLab"
        case .unsupported, nil:
            return nil
        }
    }

    var menuTitle: String { "Open on \(forgeName)…" }

    func helpText(slug: String) -> String { "Open \(slug) on \(forgeName)" }
}

extension ForgePresentation.Mark {
    /// Parsed once per process — the path data is constant, and
    /// `Shape.path(in:)` runs on every layout pass for every visible
    /// repo row.
    var parsedPath: Path {
        switch self {
        case .github: return Self.githubParsed
        case .gitlab: return Self.gitlabParsed
        }
    }

    private static let githubParsed = SVGPathParser.parse(Self.github.pathData)
    private static let gitlabParsed = SVGPathParser.parse(Self.gitlab.pathData)
}

/// Monochrome forge logo for the sidebar's project rows, tinted by
/// the caller (theme.sidebarDimIcon) to match the other sidebar
/// chrome. @spec PROJECT-2.0
struct ForgeLogoMark: View {
    let mark: ForgePresentation.Mark
    let color: Color

    var body: some View {
        // eoFill matches the fill-rule="evenodd" the Octicons SVGs
        // declare; equivalent to nonzero for today's single-contour
        // marks, but correct if upstream path data ever gains holes.
        SVGPathShape(parsed: mark.parsedPath, viewBox: mark.viewBox)
            .fill(color, style: FillStyle(eoFill: true))
    }
}
