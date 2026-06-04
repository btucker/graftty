import SwiftUI

/// Renders an SVG path-data string (the `d` attribute) as a SwiftUI
/// `Shape`, uniformly scaling the declared viewBox to the proposed
/// rect. Exists so the sidebar's forge marks (ForgeLogoMark) can be
/// drawn from vendored vector data with no bundled image resources —
/// this project has shipped broken releases from resource-bundling
/// gaps, so geometry-in-code is deliberate.
struct SVGPathShape: Shape {
    let pathData: String
    let viewBox: CGSize

    func path(in rect: CGRect) -> Path {
        let parsed = SVGPathParser.parse(pathData)
        let scale = min(rect.width / viewBox.width, rect.height / viewBox.height)
        let transform = CGAffineTransform(translationX: rect.minX, y: rect.minY)
            .scaledBy(x: scale, y: scale)
        return parsed.applying(transform)
    }
}

/// Minimal SVG path-data parser covering the command set the vendored
/// forge marks use: M/m, L/l (incl. implicit repetition), H/h, V/v,
/// C/c, S/s, A/a, Z/z. Unsupported commands abort the remainder of
/// the string, leaving whatever was parsed so far.
enum SVGPathParser {

    static func parse(_ d: String) -> Path {
        var path = Path()
        var current = CGPoint.zero
        var subpathStart = CGPoint.zero
        /// Reflected control point for S — the previous C/S command's
        /// second control point, when the previous command was a cubic.
        var lastCubicControl: CGPoint?

        let tokens = tokenize(d)
        var index = 0

        func numbers(_ count: Int) -> [CGFloat]? {
            var result: [CGFloat] = []
            while result.count < count, index < tokens.count {
                guard case .number(let value) = tokens[index] else { return nil }
                result.append(value)
                index += 1
            }
            return result.count == count ? result : nil
        }

        var command: Character = " "
        while index < tokens.count {
            if case .command(let c) = tokens[index] {
                command = c
                index += 1
            }
            // (Otherwise: implicit repetition of the previous command.)

            let isRelative = command.isLowercase
            let origin = isRelative ? current : .zero

            switch command.lowercased() {
            case "m":
                guard let n = numbers(2) else { return path }
                current = CGPoint(x: origin.x + n[0], y: origin.y + n[1])
                path.move(to: current)
                subpathStart = current
                lastCubicControl = nil
                // Implicit subsequent pairs are linetos.
                command = isRelative ? "l" : "L"
            case "l":
                guard let n = numbers(2) else { return path }
                current = CGPoint(x: origin.x + n[0], y: origin.y + n[1])
                path.addLine(to: current)
                lastCubicControl = nil
            case "h":
                guard let n = numbers(1) else { return path }
                current = CGPoint(x: origin.x + n[0], y: current.y)
                path.addLine(to: current)
                lastCubicControl = nil
            case "v":
                guard let n = numbers(1) else { return path }
                current = CGPoint(x: current.x, y: origin.y + n[0])
                path.addLine(to: current)
                lastCubicControl = nil
            case "c":
                guard let n = numbers(6) else { return path }
                let c1 = CGPoint(x: origin.x + n[0], y: origin.y + n[1])
                let c2 = CGPoint(x: origin.x + n[2], y: origin.y + n[3])
                current = CGPoint(x: origin.x + n[4], y: origin.y + n[5])
                path.addCurve(to: current, control1: c1, control2: c2)
                lastCubicControl = c2
            case "s":
                guard let n = numbers(4) else { return path }
                let c1: CGPoint
                if let prev = lastCubicControl {
                    c1 = CGPoint(x: 2 * current.x - prev.x, y: 2 * current.y - prev.y)
                } else {
                    c1 = current
                }
                let c2 = CGPoint(x: origin.x + n[0], y: origin.y + n[1])
                current = CGPoint(x: origin.x + n[2], y: origin.y + n[3])
                path.addCurve(to: current, control1: c1, control2: c2)
                lastCubicControl = c2
            case "a":
                guard let n = numbers(7) else { return path }
                let end = CGPoint(x: origin.x + n[5], y: origin.y + n[6])
                appendArc(
                    to: &path, from: current,
                    rx: n[0], ry: n[1],
                    xAxisRotationDegrees: n[2],
                    largeArc: n[3] != 0, sweep: n[4] != 0,
                    end: end
                )
                current = end
                lastCubicControl = nil
            case "z":
                path.closeSubpath()
                current = subpathStart
                lastCubicControl = nil
            default:
                return path
            }
        }
        return path
    }

    // MARK: - Tokenizer

    private enum Token {
        case command(Character)
        case number(CGFloat)
    }

    /// SVG number tokenization: `-` begins a new number, and a second
    /// `.` within one number begins a new number (`"20.3.9814"` →
    /// 20.3, .9814). Commas and whitespace are separators.
    private static func tokenize(_ d: String) -> [Token] {
        var tokens: [Token] = []
        var current = ""
        func flush() {
            if !current.isEmpty, let value = Double(current.hasPrefix(".") ? "0" + current : current) {
                tokens.append(.number(CGFloat(value)))
            }
            current = ""
        }
        for ch in d {
            if ch.isLetter {
                flush()
                tokens.append(.command(ch))
            } else if ch == "," || ch.isWhitespace {
                flush()
            } else if ch == "-" {
                flush()
                current = "-"
            } else if ch == "." && current.contains(".") {
                flush()
                current = "."
            } else {
                current.append(ch)
            }
        }
        flush()
        return tokens
    }

    // MARK: - Elliptical arc → cubic beziers

    /// W3C SVG implementation notes, appendix B.2.4: convert endpoint
    /// parameterization to center parameterization, then emit one
    /// cubic per <=90° arc segment.
    private static func appendArc(
        to path: inout Path, from start: CGPoint,
        rx: CGFloat, ry: CGFloat,
        xAxisRotationDegrees: CGFloat,
        largeArc: Bool, sweep: Bool,
        end: CGPoint
    ) {
        guard rx != 0, ry != 0, start != end else {
            path.addLine(to: end)
            return
        }
        var rx = abs(rx), ry = abs(ry)
        let phi = xAxisRotationDegrees * .pi / 180
        let cosPhi = cos(phi), sinPhi = sin(phi)

        // (x1', y1')
        let dx = (start.x - end.x) / 2, dy = (start.y - end.y) / 2
        let x1p = cosPhi * dx + sinPhi * dy
        let y1p = -sinPhi * dx + cosPhi * dy

        // Correct out-of-range radii.
        let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1 {
            let s = sqrt(lambda)
            rx *= s
            ry *= s
        }

        // (cx', cy')
        let num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
        let den = rx * rx * y1p * y1p + ry * ry * x1p * x1p
        let coef = (largeArc != sweep ? 1.0 : -1.0) * sqrt(max(0, num / den))
        let cxp = coef * (rx * y1p / ry)
        let cyp = coef * (-ry * x1p / rx)

        // (cx, cy)
        let cx = cosPhi * cxp - sinPhi * cyp + (start.x + end.x) / 2
        let cy = sinPhi * cxp + cosPhi * cyp + (start.y + end.y) / 2

        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let dot = ux * vx + uy * vy
            let len = sqrt((ux * ux + uy * uy) * (vx * vx + vy * vy))
            var a = acos(min(1, max(-1, dot / len)))
            if ux * vy - uy * vx < 0 { a = -a }
            return a
        }

        let theta1 = angle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
        var deltaTheta = angle(
            (x1p - cxp) / rx, (y1p - cyp) / ry,
            (-x1p - cxp) / rx, (-y1p - cyp) / ry
        )
        if !sweep && deltaTheta > 0 { deltaTheta -= 2 * .pi }
        if sweep && deltaTheta < 0 { deltaTheta += 2 * .pi }

        // Split into <=90° segments, each approximated by one cubic.
        let segments = max(1, Int(ceil(abs(deltaTheta) / (.pi / 2))))
        let delta = deltaTheta / CGFloat(segments)
        // Control-point distance for a unit-circle arc of angle `delta`.
        let t = 4 / 3 * tan(delta / 4)

        var theta = theta1
        for _ in 0..<segments {
            let theta2 = theta + delta
            func point(_ a: CGFloat) -> CGPoint {
                CGPoint(
                    x: cx + rx * cos(a) * cosPhi - ry * sin(a) * sinPhi,
                    y: cy + rx * cos(a) * sinPhi + ry * sin(a) * cosPhi
                )
            }
            func derivative(_ a: CGFloat) -> CGPoint {
                CGPoint(
                    x: -rx * sin(a) * cosPhi - ry * cos(a) * sinPhi,
                    y: -rx * sin(a) * sinPhi + ry * cos(a) * cosPhi
                )
            }
            let p1 = point(theta), p2 = point(theta2)
            let d1 = derivative(theta), d2 = derivative(theta2)
            path.addCurve(
                to: p2,
                control1: CGPoint(x: p1.x + t * d1.x, y: p1.y + t * d1.y),
                control2: CGPoint(x: p2.x - t * d2.x, y: p2.y - t * d2.y)
            )
            theta = theta2
        }
    }
}
