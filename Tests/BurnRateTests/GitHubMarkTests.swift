import BurnRateCore
import SwiftUI
import Testing
@testable import BurnRate

struct GitHubMarkTests {
    @Test func parsesOctocatPath() {
        let path = SVGPath.parse(GitHubMark.svgData)
        #expect(!path.isEmpty)
        let bounds = path.boundingRect
        // 16×16 Octicons viewBox; arcs/splines approximate but stay in-box.
        #expect(bounds.width > 15.8 && bounds.width <= 16.01)
        #expect(bounds.height > 14 && bounds.height <= 16.01)
    }

    @Test func shapeScalesIntoTargetRect() {
        let path = GitHubMark().path(in: CGRect(x: 0, y: 0, width: 32, height: 32))
        let bounds = path.boundingRect
        #expect(bounds.width > 31.5 && bounds.width <= 32.01)
    }

    @Test func parserHandlesAbsoluteLinesAndClose() {
        let path = SVGPath.parse("M0 0 L10 0 L10 10 Z")
        #expect(!path.isEmpty)
        #expect(abs(path.boundingRect.width - 10) < 0.001)
        #expect(abs(path.boundingRect.height - 10) < 0.001)
    }

    @Test func parserHandlesImplicitRepeatedLineto() {
        let path = SVGPath.parse("M1 1 2 0 2 0")
        #expect(abs(path.boundingRect.width - 1) < 0.001)
        #expect(abs(path.boundingRect.height - 1) < 0.001)
    }

    @Test func parserHandlesRelativeMoveAndLine() {
        let path = SVGPath.parse("m2 2 l3 0 l0 3")
        #expect(abs(path.boundingRect.width - 3) < 0.001)
        #expect(abs(path.boundingRect.height - 3) < 0.001)
    }

    @Test func parserIgnoresUnparseableCommand() {
        // A stray character must not hang or crash the parser.
        let path = SVGPath.parse("M0 0 ~ L5 5")
        #expect(path.boundingRect.width == 5)
    }
}
