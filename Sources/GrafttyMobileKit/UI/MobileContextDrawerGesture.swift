/// Gesture policy kept separate from the terminal's own selection and scrolling.
enum MobileContextDrawerGesture {
    static func shouldOpen(startX: Double, width: Double, x: Double, y: Double) -> Bool {
        width > 0 && startX >= width - 24 && startX <= width && x < -48 && abs(x) > abs(y) * 1.5
    }
}
