import Foundation
import Testing
@testable import GrafttyKit

@Suite("Provider sleep activity")
struct ProviderSleepActivityTests {
    @Test("@spec SLEEP-20: When a Claude Stop or SubagentStop hook omits or malforms task or cron registries, the application shall report unknown provider sleep activity.")
    func missingRegistries() {
        for event in ["Stop", "SubagentStop"] {
            let payloads: [[String: Any]] = [[:], ["background_tasks": []], ["session_crons": []], ["background_tasks": NSNull(), "session_crons": []], ["background_tasks": [], "session_crons": "invalid"]]
            for payload in payloads {
                #expect(ProviderSleepActivity.claudeHook(payload: payload, event: event) == .unknown)
            }
        }
    }

    @Test("@spec SLEEP-21: When a Claude hook reports any in-flight task or scheduled wakeup, the application shall report busy provider sleep activity.")
    func pendingWork() {
        for event in ["Stop", "SubagentStop"] {
            #expect(ProviderSleepActivity.claudeHook(payload: ["background_tasks": [["status": "running"]]], event: event) == .busy)
            #expect(ProviderSleepActivity.claudeHook(payload: ["session_crons": [["recurring": false]]], event: event) == .busy)
        }
    }

    @Test("@spec SLEEP-22: When a Claude stop hook is already continuing from a stop hook, the application shall report unknown provider sleep activity.")
    func stopHookContinuation() {
        #expect(ProviderSleepActivity.claudeHook(payload: ["stop_hook_active": true, "background_tasks": [], "session_crons": []], event: "Stop") == .unknown)
    }

    @Test("@spec SLEEP-23: When a Claude Stop or SubagentStop hook reports empty registries, the application shall retain unknown activity because stop hooks cannot confirm final top-level idle.")
    func emptyRegistriesDoNotProveIdle() {
        for event in ["Stop", "SubagentStop"] {
            #expect(ProviderSleepActivity.claudeHook(payload: ["stop_hook_active": false, "background_tasks": [], "session_crons": []], event: event) == .unknown)
        }
    }

    @Test("@spec SLEEP-24: When a Claude prompt or tool hook runs, the application shall report busy provider sleep activity and shall treat unrecognized events as unknown.")
    func activeEvents() {
        for event in ["UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionRequest"] {
            #expect(ProviderSleepActivity.claudeHook(payload: [:], event: event) == .busy)
        }
        for event in ["SessionStart", "SessionEnd", "new-event"] {
            #expect(ProviderSleepActivity.claudeHook(payload: [:], event: event) == .unknown)
        }
    }
}
