// Sources/GrafttyKit/Ports/PortBindingsModel.swift
import Foundation
import Combine
import GrafttyProtocol

@MainActor
public final class PortBindingsModel: ObservableObject {
    @Published public private(set) var bindings: [PaneSlotID: [PortBinding]] = [:]

    public init() {}

    public func ports(for paneIDs: [PaneSlotID]) -> [WorktreePort] {
        PortBinding.worktreePorts(from: paneIDs.flatMap { bindings[$0] ?? [] })
    }

    public func set(_ id: PaneSlotID, _ list: [PortBinding]) {
        if list.isEmpty {
            guard bindings[id] != nil else { return }
            bindings.removeValue(forKey: id)
        } else {
            guard bindings[id] != list else { return }
            bindings[id] = list
        }
    }
}
