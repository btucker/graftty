import CoreGraphics

enum TerminalChromeViewport {
    static func terminalSize(container: CGSize, chromeHeight: CGFloat?) -> CGSize {
        let reservedHeight = max(0, chromeHeight ?? 0)
        return CGSize(
            width: container.width,
            height: max(1, container.height - reservedHeight)
        )
    }
}
