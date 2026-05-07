// Sources/GrafttyKit/Ports/PortBinding.swift
import Foundation

public struct PortBinding: Hashable, Sendable {
    public let port: UInt16
    public let scope: BindScope
    public let processName: String
    public let pid: pid_t

    public init(port: UInt16, scope: BindScope, processName: String, pid: pid_t) {
        self.port = port
        self.scope = scope
        self.processName = processName
        self.pid = pid
    }
}

public enum BindScope: Sendable, Hashable {
    case loopback
    case lan
}
