import Foundation

struct RecognitionDiagnostic: Codable, Identifiable {
    enum Stage: String, Codable { case capture, classification }
    enum Outcome: String, Codable { case success, unchanged, failure, cancelled }
    var id = UUID()
    var startedAt: Date
    var endedAt: Date?
    var stage: Stage = .capture
    var outcome: Outcome?
    var code: String?
    var elapsedSeconds: TimeInterval { max(0, (endedAt ?? startedAt).timeIntervalSince(startedAt)) }

    // No localized error descriptions: they can contain URLs, credentials or response text.
    static func errorCode(_ error: Error) -> String {
        if error is CancellationError { return "cancelled" }
        if let error = error as? URLError { return "network_\(error.code.rawValue)" }
        if let error = error as? AutomaticError {
            switch error {
            case .permission: return "screen_permission"
            case .noWindow: return "no_window"
            case .imageTooLarge: return "image_budget"
            case .invalidResponse: return "invalid_response"
            default: return "configuration"
            }
        }
        if case AIError.http(let status) = error { return "http_\(status)" }
        if case AIError.keychain = error { return "keychain" }
        return "other"
    }
}
