import CoreImage
import Foundation
import Testing
@testable import GrafttyKit

@Suite
struct QRCodeDataTests {

    @Test
    func encodesShortURL() throws {
        let image = QRCodeEncoder.encode("http://mac.tailnet.ts.net:8799/", size: 200)
        let ciImage = try #require(image)
        #expect(ciImage.extent.width >= 20)
        #expect(ciImage.extent.height >= 20)
    }

    @Test
    func returnsNilForEmptyString() {
        #expect(QRCodeEncoder.encode("", size: 200) == nil)
    }
}
