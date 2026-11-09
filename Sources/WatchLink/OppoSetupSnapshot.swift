import Foundation

/// Reportable observations from one authenticated first-setup attempt. Numeric
/// OOBE state is separate from account binding, which this implementation does
/// not execute or verify. No account data, key or protocol payload is retained.
struct OppoSetupSnapshot: Codable, Equatable {
    var status = "NOT_STARTED"
    var phase: OppoSetup.Phase = .idle
    var startWriteAcknowledged = false
    var queryWriteAcknowledged = false
    var preQueryObservation: OppoSetup.StateObservation?
    var latestObservation: OppoSetup.StateObservation?
    var observations: [OppoSetup.StateObservation] = []
    var diagnostics = OppoSetup.Diagnostics()
    var error: OppoSetup.Failure?
    var startedAt: Date?
    var completedAt: Date?
    var accountBinding = "NOT_IMPLEMENTED"

    var isRunning: Bool {
        phase == .startSetting || phase == .queryState || phase == .observing
    }

    var deviceSetupFinishedReported: Bool {
        status == OppoSetup.Outcome.deviceReportedFinished.rawValue
            && queryWriteAcknowledged && latestObservation?.result == 60
    }

    var summary: String {
        switch status {
        case "START_SETTING": return "正在发送首次设置请求"
        case "QUERY_OOBE_STATE": return "首次设置请求已写入 · 正在查询手表状态"
        case "OBSERVING_DEVICE_STATE": return latestObservation?.summary ?? "正在等待手表首次设置状态"
        case "DEVICE_SETUP_FINISHED_REPORTED": return "手表报告首次设置已完成 · 账号绑定未验证"
        case "DEVICE_SETUP_PENDING": return latestObservation?.summary ?? "首次设置仍待完成"
        case "DEVICE_STATE_UNRECOGNIZED": return latestObservation?.summary ?? "首次设置状态尚未识别"
        case "FAILED": return error?.message ?? "首次设置验证未完成"
        case "INTERRUPTED": return "首次设置验证已中断 · 本次观测已保留"
        default: return "身份验证后可继续发送首次设置请求"
        }
    }

    var buttonTitle: String {
        switch status {
        case "START_SETTING": return "正在开始首次设置…"
        case "QUERY_OOBE_STATE", "OBSERVING_DEVICE_STATE": return "正在观察手表设置状态…"
        case "DEVICE_SETUP_FINISHED_REPORTED": return "手表已报告设置完成"
        case "DEVICE_SETUP_PENDING": return "本轮观察结束 · 设置仍待完成"
        case "DEVICE_STATE_UNRECOGNIZED": return "本轮观察结束 · 状态待分析"
        case "FAILED": return "本轮首次设置未完成"
        case "INTERRUPTED": return "本轮首次设置已中断"
        default: return "继续首次设置"
        }
    }
}
