import Foundation

public struct AWSHostProvider: HostProvider {
    public let identifier = "aws"
    private let enrollment: AWSHostEnrollment

    public init(enrollment: AWSHostEnrollment) {
        self.enrollment = enrollment
    }

    public func prepareConnection(operationID: UUID, parent: LinuxHostTrustRequest) async throws -> HostProviderConnection {
        connection(try await enrollment.prepareConnection(operationID: operationID, parent: parent))
    }

    public func authorize(_ candidate: HostProviderConnection, parent: LinuxHostTrustRequest) throws {
        let plan = try enrollment.connectionPlan(operationID: candidate.binding.operationID, parent: parent)
        guard connection(plan) == candidate else { throw ProviderError("The saved AWS connection binding changed.") }
    }

    private func connection(_ plan: AWSHostConnectionPlan) -> HostProviderConnection {
        .init(binding: .init(provider: identifier, operationID: plan.operationID), target: plan.target.instanceID,
              identity: plan.identity, transport: .proxy(command: "aws", arguments: plan.arguments))
    }
}
