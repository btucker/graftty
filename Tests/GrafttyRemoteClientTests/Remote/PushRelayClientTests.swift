import Foundation
import GrafttyProtocol
import Testing
@testable import GrafttyRemoteClient

@Suite struct PushRelayClientTests {
    @Test("@spec NOTIF-1.17: When enrolling a phone with Graftty-server, the application shall send its APNs token and encryption public key over authenticated HTTPS using the server's registration contract.")
    func phoneEnrollment() async throws {
        let client = try PushRelayClient(baseURL: URL(string: "https://relay.example")!) { request in
            #expect(request.url?.path == "/v1/devices/register")
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer enrollment")
            let data = try #require(request.httpBody)
            let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(body["kind"] as? String == "phone")
            #expect(body["display_name"] as? String == "iPhone")
            #expect(body["apns_token"] as? String == "abcd")
            #expect(body["hpke_pub_b64"] as? String == "AQI=")
            return (Data(#"{"device_id":"phone","device_token":"credential"}"#.utf8),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let registered = try await client.register(enrollmentToken: "enrollment", kind: .phone,
            displayName: "iPhone", apnsToken: "abcd", publicKey: Data([1, 2]))
        #expect(registered.deviceID == "phone")
        #expect(registered.deviceToken == "credential")
        #expect(throws: PushRelayClient.Failure.invalidServerURL) {
            try PushRelayClient(baseURL: URL(string: "http://relay.example")!)
        }
        #expect(throws: PushRelayClient.Failure.invalidServerURL) {
            try PushRelayClient(baseURL: URL(string: "https://user:password@relay.example")!)
        }
    }

    @Test("@spec NOTIF-1.18: When Graftty-server batches or rejects a push, the application shall preserve that delivery result instead of reporting that APNs delivered it.")
    func preservesDeliveryResult() async throws {
        let client = try PushRelayClient(baseURL: URL(string: "https://relay.example")!) { request in
            #expect(request.url?.path == "/v1/push")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer device")
            return (Data(#"{"status":"PUSH_STATUS_BATCHED","todayCount":11,"tier":"TIER_3_BATCHED","plan":"PLAN_FREE"}"#.utf8),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let request = try PushRelayRequest(clientEventId: "event", sourceDeviceName: "Mac",
            targets: [.init(phoneDeviceId: "phone", hpkeEncap: Data([1]), ciphertext: Data([2]))])
        #expect(try await client.send(request, deviceToken: "device").status == .batched)
        let unauthorized = try PushRelayClient(baseURL: URL(string: "https://relay.example")!) { request in
            (Data(), HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!)
        }
        await #expect(throws: PushRelayClient.Failure.httpStatus(401)) {
            try await unauthorized.send(request, deviceToken: "expired")
        }
    }

    @Test func updatesRotatedTokenAndReadsPhoneKeys() async throws {
        let client = try PushRelayClient(baseURL: URL(string: "https://relay.example")!) { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            if request.httpMethod == "PATCH" {
                #expect(request.url?.path == "/v1/devices/phone")
                let data = try #require(request.httpBody)
                let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
                #expect(body["apns_token"] as? String == "rotated")
                #expect(body["hpke_pub"] as? String == "AQI=")
                #expect(body["hpke_pub_b64"] == nil)
                return (Data(), response)
            }
            #expect(request.url?.path == "/v1/status")
            return (Data(#"{"plan":"free","today_count":0,"tier":2,"phones":[{"device_id":"phone","display_name":"iPhone","hpke_pub":"AQI="}]}"#.utf8), response)
        }
        try await client.updatePhone(deviceID: "phone", deviceToken: "device", apnsToken: "rotated", publicKey: Data([1, 2]))
        let status = try await client.status(deviceToken: "device")
        #expect(status.phones.first?.publicKey == Data([1, 2]))
        await #expect(throws: PushRelayClient.Failure.invalidResponse) {
            try await client.updatePhone(deviceID: "../account", deviceToken: "device", apnsToken: "rotated", publicKey: Data([1, 2]))
        }
    }
}
