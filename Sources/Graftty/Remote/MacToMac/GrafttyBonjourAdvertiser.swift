import Foundation
import GrafttyKit
import GrafttyProtocol

final class GrafttyBonjourAdvertiser: NSObject {
    enum StartError: Error, Equatable {
        case invalidPort(Int)
        case txtRecordRejected
    }

    private let port: Int
    private let label: String
    private let deviceID: RemoteDeviceID
    private let fingerprint: RemoteIdentityFingerprint
    private let protocolVersion: String
    private let pairingStatus: GrafttyBonjourService.PairingStatus
    private let serviceName: String
    private var service: NetService?

    init(
        port: Int,
        label: String,
        deviceID: RemoteDeviceID,
        fingerprint: RemoteIdentityFingerprint,
        protocolVersion: String,
        pairingStatus: GrafttyBonjourService.PairingStatus = .required,
        serviceName: String? = nil
    ) {
        self.port = port
        self.label = label
        self.deviceID = deviceID
        self.fingerprint = fingerprint
        self.protocolVersion = protocolVersion
        self.pairingStatus = pairingStatus
        self.serviceName = serviceName ?? label
        super.init()
    }

    func start() throws {
        stop()
        guard (1...65_535).contains(port),
              let servicePort = Int32(exactly: port)
        else {
            throw StartError.invalidPort(port)
        }

        let service = NetService(
            domain: GrafttyBonjourService.domain,
            type: GrafttyBonjourService.serviceType,
            name: serviceName,
            port: servicePort
        )
        service.delegate = self
        guard service.setTXTRecord(
            try Self.txtRecordData(
                label: label,
                deviceID: deviceID,
                fingerprint: fingerprint,
                protocolVersion: protocolVersion,
                pairingStatus: pairingStatus
            )
        ) else {
            throw StartError.txtRecordRejected
        }
        service.publish()
        self.service = service
    }

    func stop() {
        service?.stop()
        service?.delegate = nil
        service = nil
    }

    static func txtRecordData(
        label: String,
        deviceID: RemoteDeviceID,
        fingerprint: RemoteIdentityFingerprint,
        protocolVersion: String,
        pairingStatus: GrafttyBonjourService.PairingStatus
    ) throws -> Data {
        try GrafttyBonjourService.encodeTXT(
            GrafttyBonjourService.DiscoveryMetadata(
                deviceID: deviceID,
                label: label,
                fingerprint: fingerprint,
                protocolVersion: protocolVersion,
                pairingStatus: pairingStatus
            )
        )
    }
}

extension GrafttyBonjourAdvertiser: NetServiceDelegate {}
