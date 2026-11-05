import MessageUI
import UIKit

/// Presents Apple's own compose sheets and opens system URLs. Nothing is ever sent without the user
/// tapping Send in Apple's UI; the app only learns whether it was sent, cancelled, or failed.
@MainActor
enum SystemUI {
    static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive } ?? UIApplication.shared.connectedScenes.first as? UIWindowScene
        var top = scene?.windows.first(where: \.isKeyWindow)?.rootViewController ?? scene?.windows.first?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }

    enum ComposeResult: String {
        case sent, cancelled, failed, saved, unavailable
    }

    // UIKit calls these on the main thread; the protocols' isolation differs between SDKs, so the
    // methods are nonisolated and assert main-thread isolation themselves.
    private final class MessageDelegate: NSObject, MFMessageComposeViewControllerDelegate {
        var continuation: CheckedContinuation<ComposeResult, Never>?
        nonisolated func messageComposeViewController(_ controller: MFMessageComposeViewController, didFinishWith result: MessageComposeResult) {
            MainActor.assumeIsolated {
                controller.dismiss(animated: true)
                let mapped: ComposeResult = result == .sent ? .sent : (result == .cancelled ? .cancelled : .failed)
                continuation?.resume(returning: mapped)
                continuation = nil
            }
        }
    }

    private final class MailDelegate: NSObject, MFMailComposeViewControllerDelegate {
        var continuation: CheckedContinuation<ComposeResult, Never>?
        nonisolated func mailComposeController(_ controller: MFMailComposeViewController, didFinishWith result: MFMailComposeResult, error: Error?) {
            MainActor.assumeIsolated {
                controller.dismiss(animated: true)
                let mapped: ComposeResult
                switch result {
                case .sent: mapped = .sent
                case .saved: mapped = .saved
                case .cancelled: mapped = .cancelled
                default: mapped = .failed
                }
                continuation?.resume(returning: mapped)
                continuation = nil
            }
        }
    }

    private static var activeDelegate: NSObject?

    static func composeMessage(to recipients: [String], body: String) async -> ComposeResult {
        guard MFMessageComposeViewController.canSendText(), let top = topViewController() else { return .unavailable }
        let delegate = MessageDelegate()
        activeDelegate = delegate
        defer { activeDelegate = nil }
        return await withCheckedContinuation { cont in
            delegate.continuation = cont
            let vc = MFMessageComposeViewController()
            vc.recipients = recipients
            vc.body = body
            vc.messageComposeDelegate = delegate
            top.present(vc, animated: true)
        }
    }

    static func composeMail(to recipients: [String], subject: String, body: String) async -> ComposeResult {
        guard MFMailComposeViewController.canSendMail(), let top = topViewController() else { return .unavailable }
        let delegate = MailDelegate()
        activeDelegate = delegate
        defer { activeDelegate = nil }
        return await withCheckedContinuation { cont in
            delegate.continuation = cont
            let vc = MFMailComposeViewController()
            vc.setToRecipients(recipients)
            vc.setSubject(subject)
            vc.setMessageBody(body, isHTML: false)
            vc.mailComposeDelegate = delegate
            top.present(vc, animated: true)
        }
    }

    static func open(_ url: URL) async -> Bool {
        await UIApplication.shared.open(url)
    }
}
