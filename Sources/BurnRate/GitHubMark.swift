import SwiftUI

/// GitHub's mark, drawn from the official 16×16 Octicons path. SF Symbols
/// carries no brand glyphs, so the path is parsed and drawn instead of
/// shipping an image resource.
struct GitHubMark: Shape {
    /// Octicons `mark-github-16` (MIT).
    static let svgData = "M6.766 11.328c-2.063-.25-3.516-1.734-3.516-3.656 0-.781.281-1.625.75-2.188-.203-.515-.172-1.609.063-2.062.625-.078 1.468.25 1.968.703.594-.187 1.219-.281 1.985-.281.765 0 1.39.094 1.953.265.484-.437 1.344-.765 1.969-.687.218.422.25 1.515.046 2.047.5.593.766 1.39.766 2.203 0 1.922-1.453 3.375-3.547 3.64.531.344.89 1.094.89 1.954v1.625c0 .468.391.734.86.547C13.781 14.359 16 11.53 16 8.03 16 3.61 12.406 0 7.984 0 3.563 0 0 3.61 0 8.031a7.88 7.88 0 0 0 5.172 7.422c.422.156.828-.125.828-.547v-1.25c-.219.094-.5.156-.75.156-1.031 0-1.64-.562-2.078-1.609-.172-.422-.36-.672-.719-.719-.187-.015-.25-.093-.25-.187 0-.188.313-.328.625-.328.453 0 .844.281 1.25.86.313.452.64.655 1.031.655s.641-.14 1-.5c.266-.265.47-.5.657-.656"

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 16
        let centred = CGAffineTransform(
            translationX: rect.minX + (rect.width - 16 * scale) / 2,
            y: rect.minY + (rect.height - 16 * scale) / 2
        )
        let transform = CGAffineTransform(scaleX: scale, y: scale).concatenating(centred)
        return SVGPath.parse(Self.svgData).applying(transform)
    }
}

/// Minimal SVG path-data parser → SwiftUI `Path`. Supports the commands the
/// GitHub mark uses (M/m, L/l, H/h, V/v, C/c, S/s, Q/q, T/t, A/a, Z/z) plus
/// implicit repeated coordinate sets. Internal for tests.
enum SVGPath {
    private enum Token {
        case command(Character)
        case number(CGFloat)
    }

    static func parse(_ data: String) -> Path {
        let tokens = tokenize(data)
        var path = Path()
        var index = 0
        var current = CGPoint.zero
        var subpathStart = CGPoint.zero
        var lastCommand: Character = "M"
        var lastControl: CGPoint?
        var lastQuadControl: CGPoint?

        func number() -> CGFloat? {
            guard index < tokens.count, case .number(let value) = tokens[index] else { return nil }
            index += 1
            return value
        }
        func point(_ x: CGFloat, _ y: CGFloat, relative: Bool) -> CGPoint {
            relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
        }

        while index < tokens.count {
            var command = lastCommand
            if case .command(let c) = tokens[index] {
                command = c
                index += 1
            }
            lastCommand = command
            let relative = command.isLowercase
            // After a moveto, subsequent implicit coordinate pairs are linetos.
            var isFirstMove = command.uppercased() == "M"

            switch command.uppercased() {
            case "M":
                while let x = number(), let y = number() {
                    let p = point(x, y, relative: relative)
                    if isFirstMove {
                        path.move(to: p)
                        subpathStart = p
                        isFirstMove = false
                    } else {
                        path.addLine(to: p)
                    }
                    current = p
                }
                lastControl = nil
                lastQuadControl = nil
            case "L":
                while let x = number(), let y = number() {
                    let p = point(x, y, relative: relative)
                    path.addLine(to: p)
                    current = p
                }
                lastControl = nil
                lastQuadControl = nil
            case "H":
                while let x = number() {
                    let p = CGPoint(x: relative ? current.x + x : x, y: current.y)
                    path.addLine(to: p)
                    current = p
                }
                lastControl = nil
                lastQuadControl = nil
            case "V":
                while let y = number() {
                    let p = CGPoint(x: current.x, y: relative ? current.y + y : y)
                    path.addLine(to: p)
                    current = p
                }
                lastControl = nil
                lastQuadControl = nil
            case "C":
                while let x1 = number(), let y1 = number(), let x2 = number(),
                      let y2 = number(), let x = number(), let y = number() {
                    let c1 = point(x1, y1, relative: relative)
                    let c2 = point(x2, y2, relative: relative)
                    let end = point(x, y, relative: relative)
                    path.addCurve(to: end, control1: c1, control2: c2)
                    lastControl = c2
                    lastQuadControl = nil
                    current = end
                }
            case "S":
                while let x2 = number(), let y2 = number(), let x = number(), let y = number() {
                    let c1 = lastControl.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                    let c2 = point(x2, y2, relative: relative)
                    let end = point(x, y, relative: relative)
                    path.addCurve(to: end, control1: c1, control2: c2)
                    lastControl = c2
                    lastQuadControl = nil
                    current = end
                }
            case "Q":
                while let x1 = number(), let y1 = number(), let x = number(), let y = number() {
                    let control = point(x1, y1, relative: relative)
                    let end = point(x, y, relative: relative)
                    path.addQuadCurve(to: end, control: control)
                    lastQuadControl = control
                    lastControl = nil
                    current = end
                }
            case "T":
                while let x = number(), let y = number() {
                    let control = lastQuadControl.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                    let end = point(x, y, relative: relative)
                    path.addQuadCurve(to: end, control: control)
                    lastQuadControl = control
                    lastControl = nil
                    current = end
                }
            case "A":
                while let rx = number(), let ry = number(), let rotation = number(),
                      let largeArc = number(), let sweep = number(),
                      let x = number(), let y = number() {
                    let end = point(x, y, relative: relative)
                    addArc(to: &path, from: current, to: end, rx: rx, ry: ry,
                           rotationDegrees: rotation, largeArc: largeArc != 0, sweep: sweep != 0)
                    current = end
                    lastControl = nil
                    lastQuadControl = nil
                }
            case "Z":
                path.closeSubpath()
                current = subpathStart
                lastControl = nil
                lastQuadControl = nil
            default:
                // Unrecognised command: drop a token so the loop can't spin.
                index += 1
            }
        }
        return path
    }

    // MARK: - Tokenizer

    private static func tokenize(_ data: String) -> [Token] {
        let characters = Array(data)
        var tokens: [Token] = []
        var i = 0
        let commands: Set<Character> = ["M", "m", "L", "l", "H", "h", "V", "v",
                                        "C", "c", "S", "s", "Q", "q", "T", "t",
                                        "A", "a", "Z", "z"]

        func isSeparator(_ c: Character) -> Bool {
            c == " " || c == "," || c == "\n" || c == "\t" || c == "\r"
        }

        while i < characters.count {
            let c = characters[i]
            if isSeparator(c) {
                i += 1
            } else if commands.contains(c) {
                tokens.append(.command(c))
                i += 1
            } else {
                var text = ""
                if c == "+" || c == "-" {
                    text.append(c)
                    i += 1
                }
                while i < characters.count, characters[i].isNumber {
                    text.append(characters[i])
                    i += 1
                }
                if i < characters.count, characters[i] == "." {
                    text.append(".")
                    i += 1
                    while i < characters.count, characters[i].isNumber {
                        text.append(characters[i])
                        i += 1
                    }
                }
                if i < characters.count, characters[i] == "e" || characters[i] == "E" {
                    text.append(characters[i])
                    i += 1
                    if i < characters.count, characters[i] == "+" || characters[i] == "-" {
                        text.append(characters[i])
                        i += 1
                    }
                    while i < characters.count, characters[i].isNumber {
                        text.append(characters[i])
                        i += 1
                    }
                }
                if let value = Double(text) {
                    tokens.append(.number(CGFloat(value)))
                } else {
                    // Defensive: skip an unparseable character.
                    i += 1
                }
            }
        }
        return tokens
    }

    // MARK: - Arc → cubic

    /// Endpoint-parameterised arc (SVG spec F.6.5) split into ≤90° cubics.
    private static func addArc(
        to path: inout Path,
        from start: CGPoint,
        to end: CGPoint,
        rx rxInput: CGFloat,
        ry ryInput: CGFloat,
        rotationDegrees: CGFloat,
        largeArc: Bool,
        sweep: Bool
    ) {
        var rx = abs(rxInput)
        var ry = abs(ryInput)
        guard rx > 0, ry > 0, start != end else {
            if start != end { path.addLine(to: end) }
            return
        }
        let phi = rotationDegrees * .pi / 180
        let cosPhi = cos(phi)
        let sinPhi = sin(phi)
        let dx = (start.x - end.x) / 2
        let dy = (start.y - end.y) / 2
        let x1p = cosPhi * dx + sinPhi * dy
        let y1p = -sinPhi * dx + cosPhi * dy

        let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1 {
            let scale = sqrt(lambda)
            rx *= scale
            ry *= scale
        }

        let denominator = rx * rx * y1p * y1p + ry * ry * x1p * x1p
        let numerator = max(0, rx * rx * ry * ry - denominator)
        let sign: CGFloat = largeArc != sweep ? 1 : -1
        let coefficient = denominator == 0 ? 0 : sign * sqrt(numerator / denominator)
        let cxp = coefficient * (rx * y1p / ry)
        let cyp = coefficient * (-ry * x1p / rx)
        let cx = cosPhi * cxp - sinPhi * cyp + (start.x + end.x) / 2
        let cy = sinPhi * cxp + cosPhi * cyp + (start.y + end.y) / 2

        let theta1 = atan2((y1p - cyp) / ry, (x1p - cxp) / rx)
        let theta2 = atan2((-y1p - cyp) / ry, (-x1p - cxp) / rx)
        var delta = theta2 - theta1
        if !sweep, delta > 0 { delta -= 2 * .pi }
        if sweep, delta < 0 { delta += 2 * .pi }

        let segments = max(1, Int(ceil(abs(delta) / (.pi / 2))))
        let step = delta / CGFloat(segments)
        let alpha = 4.0 / 3.0 * tan(step / 4)

        func arcPoint(_ theta: CGFloat) -> CGPoint {
            CGPoint(x: cx + rx * cos(theta) * cosPhi - ry * sin(theta) * sinPhi,
                    y: cy + rx * cos(theta) * sinPhi + ry * sin(theta) * cosPhi)
        }
        func arcTangent(_ theta: CGFloat) -> CGPoint {
            CGPoint(x: -rx * sin(theta) * cosPhi - ry * cos(theta) * sinPhi,
                    y: -rx * sin(theta) * sinPhi + ry * cos(theta) * cosPhi)
        }

        var theta = theta1
        var cursor = start
        for _ in 0..<segments {
            let next = theta + step
            let endPoint = arcPoint(next)
            let tangent = arcTangent(theta)
            let nextTangent = arcTangent(next)
            let control1 = CGPoint(x: cursor.x + alpha * tangent.x, y: cursor.y + alpha * tangent.y)
            let control2 = CGPoint(x: endPoint.x - alpha * nextTangent.x, y: endPoint.y - alpha * nextTangent.y)
            path.addCurve(to: endPoint, control1: control1, control2: control2)
            theta = next
            cursor = endPoint
        }
    }
}
