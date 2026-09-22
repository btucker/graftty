import Foundation

/// Literal task scenes. Legacy motif names remain the persisted classification,
/// while drawings show software work rather than buildings in a themed world.
enum WorktreeTaskIllustration {
    static func svg(_ motif: WorktreeSVGMap.Motif, variant: Int) -> String {
        let v = min(2, max(0, variant))
        let name: String
        var drawing: String
        switch motif {
        case .plaza:
            name = "project-terminal"
            drawing = terminal + path("M-19 -5 l7 6 -7 6 M-7 9 H4", fill: "none")
                + path(v == 0 ? "M13 16 V1 Q-1 0 1 -12 Q12 -12 13 1 Q14 -16 26 -12 Q26 1 13 1"
                    : v == 1 ? "M7 16 V-8 H26 V16 Z M12 -2 H21 M12 4 H21" : "M8 16 V-9 L16 -15 L25 -9 V16 Z M13 2 H21 M13 8 H21")
        case .forge:
            name = ["code-repair", "code-review", "test-results"][v]
            if v == 0 {
                drawing = terminal + codeLines + path("M13 -3 Q7 -14 16 -19 L16 -11 L23 -9 L29 -15 Q32 -4 22 0 L10 20 L3 16 Z")
            } else if v == 1 {
                drawing = document + path("M-19 -9 H1 M-19 -2 H9 M-19 5 H-2", fill: "none")
                    + path("M-23 -9 H-21 M-23 2 V8 M-26 5 H-20", fill: "none")
                    + "<circle cx=\"17\" cy=\"10\" r=\"14\"/>" + check
            } else {
                drawing = terminal + path("M-20 -5 l3 3 5 -6 M-20 6 l3 3 5 -6 M-20 17 l3 3 5 -6 M-7 -5 H20 M-7 6 H13 M-7 17 H20", fill: "none")
            }
        case .beacon:
            name = ["incoming-message", "approval-request", "remote-messages"][v]
            if v == 0 {
                drawing = path("M-29 4 H-13 L-8 11 H8 L13 4 H29 V23 H-29 Z")
                    + path("M-21 -26 H21 V-4 H1 L-8 2 V-4 H-21 Z")
                    + path("M-12 -18 H12 M-12 -11 H4", fill: "none")
            } else if v == 1 {
                drawing = path("M-28 -25 H20 V5 H1 L-12 16 V5 H-28 Z")
                    + path("M-19 -15 H9 M-19 -7 H1", fill: "none")
                    + "<circle cx=\"17\" cy=\"11\" r=\"14\"/>" + check
            } else { drawing = computers + path("M-15 -13 H5 V-1 H-2 L-7 4 V-1 H-15 Z") + path("M-4 -23 Q15 -29 27 -10 M20 -13 L27 -10 L29 -18", fill: "none") }
        case .observatory:
            name = ["search-results", "file-index", "incoming-events"][v]
            if v == 0 {
                drawing = terminal + path("M-22 -4 H7 M-22 5 H-5 M-22 14 H1", fill: "none")
                    + "<circle cx=\"14\" cy=\"3\" r=\"11\"/>" + path("M22 11 L30 23", fill: "none")
            } else if v == 1 {
                drawing = document + path("M-21 -13 H-13 V-5 H-21 Z M-21 0 H-13 V8 H-21 Z M-21 13 H-13 V21 H-21 Z M-8 -9 H9 M-8 4 H9 M-8 17 H9", fill: "none")
            } else {
                drawing = terminal + path("M-23 0 H-12 L-6 -8 L0 9 L6 -2 H23 M-22 17 H-3", fill: "none")
                    + "<circle cx=\"18\" cy=\"-23\" r=\"7\"/>"
            }
        case .canal:
            name = ["terminal-history", "terminal-scrollback", "split-streams"][v]
            if v == 0 { drawing = path("M-27 -28 H16 V10 H-27 Z M-20 -21 H23 V17 H-20 Z") + terminal + codeLines }
            else if v == 1 { drawing = terminal + codeLines + path("M19 -8 V18 M16 -8 H22 V1 H16 Z", fill: "none") + path("M-16 27 H9 M-10 31 H3", fill: "none") }
            else { drawing = terminal + path("M0 -10 V21 M-22 -2 H-5 M-22 5 H-11 M6 -2 H22 M6 5 H15 M-22 15 H-5 M6 15 H22", fill: "none") }
        case .garden:
            name = ["color-editing", "artwork-options", "image-browser"][v]
            if v == 0 {
                drawing = "<circle cx=\"-6\" cy=\"0\" r=\"24\"/>" + path("M-22 -4 H-11 V7 H-22 Z M-6 -17 H5 V-6 H-6 Z M-5 9 H6 V20 H-5 Z")
                    + path("M11 15 L23 -23 L30 -20 L18 17 L10 25 Z")
            } else if v == 1 {
                drawing = path("M-31 -15 L-11 -25 L8 13 L-12 23 Z M-13 -26 H12 V18 H-13 Z M1 -19 H30 V23 H1 Z")
                    + path("M5 13 L12 3 L17 9 L23 -2 L27 13 Z")
                    + path("M7 18 l5 4 10 -10", fill: "none")
            } else { drawing = terminal + path("M-22 15 L-12 -1 L-3 8 L8 -4 L21 15 Z") + "<circle cx=\"-13\" cy=\"-7\" r=\"3\"/>" }
        case .archive:
            name = ["data-recovery", "partitioned-storage", "encrypted-storage"][v]
            drawing = database
            if v == 0 { drawing += path("M7 17 H28 M18 22 V-6 M10 2 L18 -6 L26 2", fill: "none") }
            else if v == 1 { drawing += path("M-23 -1 H21 M-23 9 H21 M-8 -1 V22 M8 -1 V22", fill: "none") }
            else { drawing += lock }
        case .gate:
            name = ["sign-in", "access-permissions", "device-pairing"][v]
            if v == 0 { drawing = terminal + path("M-21 -5 H-1 M-21 4 H-7 M-21 13 H-1", fill: "none") + lock }
            else if v == 1 { drawing = document + path("M-20 -11 h5 v5 h-5 Z M-20 0 h5 v5 h-5 Z M-20 11 h5 v5 h-5 Z M-10 -8 H10 M-10 3 H6 M-10 14 H1", fill: "none") + path("M11 2 L28 -2 V12 Q27 22 20 28 Q11 22 11 12 Z M15 11 l4 4 6 -9") }
            else { drawing = computers + "<circle cx=\"-3\" cy=\"-15\" r=\"7\"/>" + path("M4 -15 H22 M17 -15 V-9 M22 -15 V-9", fill: "none") }
        case .bridge:
            name = ["connected-terminals", "file-transfer", "live-sync"][v]
            drawing = computers
            if v == 0 { drawing += path("M-18 8 H0 V-6 H17 M12 -11 L17 -6 L12 -1", fill: "none") }
            else if v == 1 { drawing += path("M-9 -26 H3 L10 -19 V-6 H-9 Z M3 -26 V-19 H10") + path("M-4 0 H11 M6 -5 L11 0 L6 5", fill: "none") }
            else { drawing += path("M-14 -11 Q-3 -26 12 -13 M6 -18 L12 -13 L15 -20 M12 3 Q-3 18 -14 5 M-17 12 L-14 5 L-8 10", fill: "none") }
        case .windmill:
            name = ["performance-profile", "cache-reuse", "parallel-jobs"][v]
            if v == 0 { drawing = terminal + path("M-19 14 A19 19 0 0 1 19 14 M0 14 L11 -3 M-24 22 H24", fill: "none") + "<circle cx=\"0\" cy=\"14\" r=\"3\"/>" }
            else if v == 1 { drawing = database + path("M19 -21 L5 4 H16 L8 25 L29 -3 H17 Z") }
            else { drawing = path("M-25 -23 H-8 V-6 H-25 Z M8 -23 H25 V-6 H8 Z M-25 6 H-8 V23 H-25 Z M8 6 H25 V23 H8 Z") + path("M-17 -6 V6 M17 -6 V6 M-8 -14 H8 M-8 14 H8", fill: "none") }
        case .harbor:
            name = ["release-package", "build-package", "launch-application"][v]
            if v == 0 { drawing = package + path("M0 8 V-28 M-9 -19 L0 -28 L9 -19", fill: "none") }
            else if v == 1 { drawing = package + path("M-20 -26 H-5 V-12 H-20 Z M5 -26 H20 V-12 H5 Z M-7 -5 H7 V9 H-7 Z") }
            else { drawing = terminal + path("M-8 13 L20 -15 M5 -15 H20 V0", fill: "none") }
        }
        return "<g data-task=\"\(name)\" data-variant=\"\(v)\">\(drawing)</g>"
    }

    private static func path(_ d: String, fill: String? = nil) -> String {
        "<path d=\"\(d)\"\(fill.map { " fill=\"\($0)\"" } ?? "")/>"
    }
    private static let terminal = "<path d=\"M-29 -24 H29 V22 H-29 Z M-29 -13 H29\"/><path d=\"M-23 -18 H-20 M-16 -18 H-13\" fill=\"none\"/>"
    private static let document = "<path d=\"M-27 -27 H9 L19 -17 V25 H-27 Z M9 -27 V-17 H19\"/>"
    private static let codeLines = "<path d=\"M-21 -5 l5 4 -5 4 M-10 3 H10 M-21 13 H4\" fill=\"none\"/>"
    private static let check = "<path d=\"M10 10 l5 5 10 -11\" fill=\"none\" stroke-width=\"2.5\"/>"
    private static let computers = "<path d=\"M-31 -10 H-8 V12 H-31 Z M-20 12 V18 M-30 18 H-10 M8 -1 H31 V22 H8 Z M19 22 V28 M9 28 H29\"/>"
    private static let database = "<path d=\"M-24 -16 V19 C-24 29 22 29 22 19 V-16 Z\"/><ellipse cx=\"-1\" cy=\"-16\" rx=\"23\" ry=\"9\"/><path d=\"M-24 -5 C-24 5 22 5 22 -5 M-24 7 C-24 17 22 17 22 7\" fill=\"none\"/>"
    private static let lock = "<path d=\"M7 6 V-4 A9 9 0 0 1 25 -4 V6 M3 6 H29 V26 H3 Z\"/><path d=\"M16 13 V20\" fill=\"none\" stroke-width=\"3\"/>"
    private static let package = "<path d=\"M-27 -3 L0 -16 L27 -3 V20 L0 31 L-27 20 Z M-27 -3 L0 10 L27 -3 M0 10 V31\"/>"
}
