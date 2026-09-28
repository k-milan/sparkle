import Foundation

enum AssistantProvider: String, Sendable {
    case chatGPT = "ChatGPT"
    case claude = "Claude"
}

enum IntegrationEvent: Sendable {
    case completed(provider: AssistantProvider, title: String?)
    case needsAttention(provider: AssistantProvider, title: String?, reason: String)
}

protocol AssistantIntegration: AnyObject {
    var provider: AssistantProvider { get }
    var bundleIdentifier: String { get }
    var onEvent: (@Sendable (IntegrationEvent) -> Void)? { get set }

    func start()
    func stop()
}
