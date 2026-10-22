import Foundation

protocol AWSPaginatedResponse: Decodable {
    var NextToken: String? { get }
}

/// Keeps AWS CLI invocation, timeouts, and pagination checks consistent across discovery commands.
struct AWSReadOnlyClient: Sendable {
    enum Operation: String {
        case instances = "describe-instances"
        case instanceTypes = "describe-instance-types"
        case spotPrices = "describe-spot-price-history"
    }
    let executor: any CLIExecutor

    func query<T: AWSPaginatedResponse>(_ operation: Operation, arguments: [String] = [], profile: String, region: String) async throws -> T {
        try Task.checkCancellation()
        let args = ["ec2", operation.rawValue] + arguments + ["--profile", profile, "--region", region, "--output", "json",
            "--no-cli-pager", "--no-cli-auto-prompt", "--cli-connect-timeout", "10", "--cli-read-timeout", "20"]
        let output: CLIOutput
        do {
            output = try await executor.run(command: "aws", args: args, at: NSHomeDirectory(), timeout: .seconds(45))
        } catch CLIError.notFound {
            throw ProviderError("Install the AWS CLI v2 and configure your profile before querying the provider.")
        } catch CLIError.nonZeroExit(_, _, let stderr) {
            throw ProviderError("AWS discovery failed: \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        try Task.checkCancellation()
        let response: T
        do { response = try JSONDecoder().decode(T.self, from: Data(output.stdout.utf8)) }
        catch { throw ProviderError("AWS returned an unsupported or incomplete JSON response: \(error)") }
        guard response.NextToken?.isEmpty != false else {
            throw ProviderError("AWS returned incomplete paginated results; no discovery report was produced.")
        }
        return response
    }

}

struct AWSInstanceTypesResponse: AWSPaginatedResponse { let InstanceTypes: [AWSInstanceType]; let NextToken: String? }
struct AWSInstanceType: Decodable {
    let InstanceType: String
    let VCpuInfo: CPUs
    let MemoryInfo: Memory
    let ProcessorInfo: Processor
    let SupportedUsageClasses: [String]
    let BurstablePerformanceSupported: Bool
    struct CPUs: Decodable { let DefaultVCpus: Int }
    struct Memory: Decodable { let SizeInMiB: Int }
    struct Processor: Decodable { let SupportedArchitectures: [String] }
}
