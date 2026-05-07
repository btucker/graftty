// Sources/GrafttyKit/Ports/PortBindingsModel.swift
import Foundation
import Combine

@MainActor
public final class PortBindingsModel: ObservableObject {
    @Published public private(set) var bindings: [TerminalID: [PortBinding]] = [:]

    public init() {}

    public func set(_ id: TerminalID, _ list: [PortBinding]) {
        if list.isEmpty {
            bindings.removeValue(forKey: id)
        } else {
            bindings[id] = list
        }
    }
}
