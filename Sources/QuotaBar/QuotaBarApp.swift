import AppKit
import CoreImage
import SwiftUI

@main
struct QuotaBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            UsagePopoverView(
                store: appDelegate.store,
                addAccount: { appDelegate.showAddAccount() },
                reauthenticate: { appDelegate.showReauthentication(for: $0) }
            )
        } label: {
            QuotaBarMenuLabel(store: appDelegate.store)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(store: appDelegate.store)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = UsageStore()
    private lazy var accountFlowWindow = AccountFlowWindowController(store: store)
    private var wakeObserver: NSObjectProtocol?
    private var terminationInProgress = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Writing to a child's stdin just after it exits must fail with EPIPE, not kill the app.
        signal(SIGPIPE, SIG_IGN)
        NSApp.setActivationPolicy(.accessory)
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.store.refreshAll(includeUsage: true) }
        }
        store.start()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationInProgress else { return .terminateLater }
        terminationInProgress = true
        Task { [weak self] in
            guard let self else {
                sender.reply(toApplicationShouldTerminate: true)
                return
            }
            await store.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }

    func showAddAccount() {
        accountFlowWindow.showAddAccount()
    }

    func showReauthentication(for profile: AccountProfile) {
        accountFlowWindow.showReauthentication(for: profile)
    }
}

private struct QuotaBarMenuLabel: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        HStack(spacing: 0) {
            QuotaMenuGlyph()
            Text(title)
                .font(.system(size: 13, weight: .regular))
                .monospacedDigit()
        }
        .fixedSize()
        .help(tooltip)
        .accessibilityLabel("QuotaBar \(title)")
        .accessibilityValue(tooltip)
    }

    private var title: String {
        let snapshot = store.primarySnapshot
        if let remaining = snapshot?.remainingPercent {
            return "\(remaining)%"
        }
        if snapshot?.connectionState == .authRequired { return "!" }
        return "--"
    }

    private var tooltip: String {
        guard let profile = store.primaryProfile else { return "계정을 추가하세요." }
        guard let snapshot = store.primarySnapshot else {
            return "\(profile.alias): 아직 사용량 정보가 없습니다."
        }
        if snapshot.connectionState == .authRequired {
            return "\(profile.alias): 로그인이 필요합니다."
        }
        let windows = snapshot.displayWindows
            .map { "\(QuotaBarFormatters.windowLabel($0.windowDurationMinutes)) \($0.remainingPercent)% 남음" }
            .joined(separator: " · ")
        let usage = windows.isEmpty ? "사용량 없음" : windows
        return "\(profile.alias): \(usage), \(QuotaBarFormatters.fetchedText(snapshot.fetchedAt))"
    }

}

/// The QuotaBar gauge as a monochrome menu-bar template, matching the app icon.
private struct QuotaMenuGlyph: View {
    var body: some View {
        Image(nsImage: Self.templateImage)
            .resizable()
            .interpolation(.high)
            .frame(width: 17.5, height: 15)
        .accessibilityHidden(true)
    }

    private static let templateImage: NSImage = {
        // The view box is wider than the gauge on purpose: MenuBarExtra can collapse SwiftUI
        // padding in its label, but it keeps transparent pixels inside the image.
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 23.333333 20">
          <path d="M4.4 15.6 A7.2 7.2 0 1 1 14.6 15.6" fill="none" stroke="#000" stroke-opacity="0.38" stroke-width="2.3" stroke-linecap="round"/>
          <path d="M4.4 15.6 A7.2 7.2 0 0 1 13.1 4.2" fill="none" stroke="#000" stroke-width="2.3" stroke-linecap="round"/>
          <circle cx="9.5" cy="10.5" r="2.1" fill="#000"/>
        </svg>
        """
        let image = NSImage(data: Data(svg.utf8))
            ?? NSImage(systemSymbolName: "gauge.with.needle", accessibilityDescription: nil)
            ?? NSImage()
        image.size = NSSize(width: 17.5, height: 15)
        image.isTemplate = true
        return image
    }()
}
