import AppKit
import SwiftUI

struct UsagePopoverView: View {
    @ObservedObject var store: UsageStore
    let addAccount: () -> Void
    let reauthenticate: (AccountProfile) -> Void
    @State private var showsDetails = false

    var body: some View {
        VStack(spacing: 0) {
            PopoverHeader(store: store)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let primary = store.primaryProfile {
                        PrimaryQuotaCard(
                            profile: primary,
                            snapshot: store.primarySnapshot,
                            reauthenticate: { reauthenticate(primary) }
                        )

                        if let snapshot = store.primarySnapshot, snapshot.hasExtraDetails {
                            QuotaDetailsSection(snapshot: snapshot, isExpanded: $showsDetails)
                        }

                        let otherProfiles = store.profiles.filter { $0.id != primary.id }
                        if !otherProfiles.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                SectionTitle(title: "다른 계정", detail: "별을 눌러 대표 계정을 바꿉니다")
                                VStack(spacing: 0) {
                                    ForEach(Array(otherProfiles.enumerated()), id: \.element.id) { index, profile in
                                        OtherAccountRow(
                                            profile: profile,
                                            snapshot: store.snapshots[profile.id],
                                            makePrimary: { store.makePrimary(profile.id) },
                                            reauthenticate: { reauthenticate(profile) }
                                        )
                                        if index < otherProfiles.count - 1 {
                                            Divider().padding(.leading, 45)
                                        }
                                    }
                                }
                                .background(.quaternary.opacity(0.24), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                        }
                    } else {
                        EmptyDashboard(addAccount: addAccount)
                    }
                }
                .padding(16)
            }

            Divider()
            PopoverFooter(addAccount: addAccount)
        }
        .frame(width: 420, height: 590)
        .background(Color(nsColor: .windowBackgroundColor))
        .alert("QuotaBar", isPresented: Binding(
            get: { store.transientMessage != nil },
            set: { if !$0 { store.transientMessage = nil } }
        )) {
            Button("확인", role: .cancel) { store.transientMessage = nil }
        } message: {
            Text(store.transientMessage ?? "")
        }
    }
}

private struct PopoverHeader: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text("QUOTABAR")
                    .font(.caption2.weight(.bold))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
                Text("사용량")
                    .font(.title3.weight(.semibold))
            }
            Spacer()
            Button {
                Task { await store.refreshAll(includeUsage: true) }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("r", modifiers: .command)
            .help("모든 계정 새로고침 ⌘R")
            .accessibilityLabel("모든 계정 새로고침")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

private struct PopoverFooter: View {
    let addAccount: () -> Void
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        HStack(spacing: 10) {
            Menu {
                Button {
                    presentSettings()
                } label: {
                    Label("설정", systemImage: "gearshape")
                }
                Divider()
                Button(role: .destructive) {
                    NSApp.terminate(nil)
                } label: {
                    Label("QuotaBar 종료", systemImage: "power")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .frame(width: 28, height: 28)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("더 보기")
            .accessibilityLabel("더 보기")

            Spacer()

            Button {
                addAccount()
            } label: {
                Label("계정 추가", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    @MainActor
    private func presentSettings() {
        NSApp.activate(ignoringOtherApps: true)
        openSettings()
        bringSettingsWindowForward()

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            NSApp.activate(ignoringOtherApps: true)
            bringSettingsWindowForward()
        }
    }

    @MainActor
    private func bringSettingsWindowForward() {
        NSApp.windows
            .first { window in
                window.isVisible
                    && window.styleMask.contains(.titled)
                    && !(window is NSPanel)
            }?
            .makeKeyAndOrderFront(nil)
    }
}

private struct EmptyDashboard: View {
    let addAccount: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.12))
                Image(systemName: "chart.bar.xaxis")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: 72, height: 72)

            VStack(spacing: 6) {
                Text("Codex·Claude 사용량을 한눈에")
                    .font(.title3.weight(.semibold))
                Text("계정을 연결하면 남은 쿼터와 초기화 시각을\n메뉴바에서 바로 확인할 수 있습니다.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button(action: addAccount) {
                Label("첫 계정 연결", systemImage: "person.badge.plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Label("로그인은 Mac 안에서 Codex와 Claude Code가 직접 관리합니다", systemImage: "lock.shield")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 56)
    }
}

private struct PrimaryQuotaCard: View {
    let profile: AccountProfile
    let snapshot: AccountUsageSnapshot?
    let reauthenticate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                AccountAvatar(provider: profile.provider, snapshot: snapshot, size: 42)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(profile.alias)
                            .font(.headline)
                            .lineLimit(1)
                        PlanBadge(text: planBadgeText(profile: profile, snapshot: snapshot), tint: profile.provider.tint)
                    }
                    if let email = snapshot?.identity.email {
                        Text(email)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 0) {
                    Text(snapshot?.remainingPercent.map { "\($0)%" } ?? "—")
                        .font(.system(size: 30, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(usageColor(snapshot?.remainingPercent))
                    if let window = snapshot?.limitingWindow {
                        Text("\(QuotaBarFormatters.windowLabel(window.windowDurationMinutes)) 한도 기준")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
            }

            let rows = limitRows(snapshot)
            if !rows.isEmpty {
                VStack(spacing: 11) {
                    ForEach(rows) { row in
                        LimitBar(row: row, isLimiting: rows.count > 1 && row.window == snapshot?.limitingWindow)
                    }
                }
            }

            HStack(spacing: 6) {
                StatusLabel(snapshot: snapshot)
                Text("·")
                    .foregroundStyle(.tertiary)
                Text("\(QuotaBarFormatters.fetchedText(snapshot?.fetchedAt)) 갱신")
                    .lineLimit(1)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if snapshot?.connectionState == .authRequired {
                InlineNotice(
                    text: snapshot?.lastError ?? "로그인이 필요합니다.",
                    symbol: "key.slash",
                    tint: .orange,
                    actionTitle: "다시 로그인",
                    action: reauthenticate
                )
            } else if let error = snapshot?.lastError {
                InlineNotice(text: error, symbol: "exclamationmark.triangle", tint: .orange)
            }
        }
        .padding(16)
        .background(
            LinearGradient(
                colors: [profile.provider.tint.opacity(0.13), profile.provider.tint.opacity(0.03)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(profile.provider.tint.opacity(0.16), lineWidth: 1)
        }
    }
}

/// One limit to show for an account. A nil window is a limit the plan has but the server
/// did not report, shown as a placeholder instead of an invented number.
private struct LimitRow: Identifiable {
    let label: String
    let window: RateLimitWindow?
    var id: String { label }
}

private func limitRows(_ snapshot: AccountUsageSnapshot?) -> [LimitRow] {
    guard let snapshot else { return [] }
    var rows = snapshot.displayWindows.map {
        LimitRow(label: QuotaBarFormatters.windowLabel($0.windowDurationMinutes), window: $0)
    }
    if snapshot.isPlusFiveHourWindowMissing {
        rows.insert(LimitRow(label: "5시간", window: nil), at: 0)
    }
    return rows
}

/// A labelled bar for one limit: what is left and when it refills.
private struct LimitBar: View {
    let row: LimitRow
    let isLimiting: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 9) {
                Text(row.label)
                    .font(.caption.weight(isLimiting ? .bold : .medium))
                    .foregroundStyle(isLimiting ? Color.primary : Color.secondary)
                    .frame(width: 40, alignment: .leading)
                QuotaMeter(remaining: row.window?.remainingPercent)
                    .frame(height: 7)
                Text(row.window.map { "\($0.remainingPercent)%" } ?? "—")
                    .font(.callout.weight(.semibold).monospacedDigit())
                    .foregroundStyle(row.window == nil ? Color.secondary : usageColor(row.window?.remainingPercent))
                    .frame(width: 44, alignment: .trailing)
            }
            Text(row.window.map { resetLine($0) } ?? "Codex 응답에 이 한도가 없어 값을 표시하지 않습니다")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.leading, 49)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.window.map { "\(row.label) 한도 \($0.remainingPercent)퍼센트 남음, \(resetLine($0))" } ?? "\(row.label) 한도 정보 없음")
    }
}

/// A compact bar for account rows.
private struct MiniLimit: View {
    let row: LimitRow
    let isLimiting: Bool

    var body: some View {
        HStack(spacing: 4) {
            Text(row.label)
                .font(.caption2.weight(isLimiting ? .bold : .regular))
                .foregroundStyle(isLimiting ? Color.primary : Color.secondary)
            QuotaMeter(remaining: row.window?.remainingPercent)
                .frame(width: 34, height: 4)
            Text(row.window.map { "\($0.remainingPercent)%" } ?? "—")
                .font(.caption2.weight(.semibold).monospacedDigit())
                .foregroundStyle(row.window == nil ? Color.secondary : usageColor(row.window?.remainingPercent))
        }
        .fixedSize()
    }
}

private struct MiniLimits: View {
    let snapshot: AccountUsageSnapshot?

    var body: some View {
        let rows = limitRows(snapshot)
        HStack(spacing: 10) {
            ForEach(rows) { row in
                MiniLimit(row: row, isLimiting: rows.count > 1 && row.window == snapshot?.limitingWindow)
            }
        }
        .help(windowResetSummary(snapshot) ?? "")
    }
}

private struct QuotaMeter: View {
    let remaining: Int?

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.09))
                if let remaining, remaining > 0 {
                    Capsule()
                        .fill(usageColor(remaining))
                        .frame(width: max(proxy.size.height, proxy.size.width * CGFloat(remaining) / 100))
                }
            }
        }
    }
}

private struct OtherAccountRow: View {
    let profile: AccountProfile
    let snapshot: AccountUsageSnapshot?
    let makePrimary: () -> Void
    let reauthenticate: () -> Void

    var body: some View {
        HStack(spacing: 11) {
            AccountAvatar(provider: profile.provider, snapshot: snapshot, size: 34)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(profile.alias)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .layoutPriority(1)
                    Text(planBadgeText(profile: profile, snapshot: snapshot))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(profile.provider.tint)
                        .lineLimit(1)
                    if !profile.isEnabled {
                        Text("꺼짐")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                if let status = rowStatusText(profile: profile, snapshot: snapshot) {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(snapshot?.connectionState == .authRequired ? Color.orange : Color.secondary)
                        .lineLimit(1)
                } else {
                    MiniLimits(snapshot: snapshot)
                }
            }
            // Without this the spacer splits the free width with the name and truncates it.
            .layoutPriority(1)

            Spacer(minLength: 6)

            VStack(alignment: .trailing, spacing: 0) {
                Text(snapshot?.remainingPercent.map { "\($0)%" } ?? "—")
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .foregroundStyle(profile.isEnabled ? usageColor(snapshot?.remainingPercent) : Color.secondary)
                if let window = snapshot?.limitingWindow {
                    Text(QuotaBarFormatters.windowLabel(window.windowDurationMinutes))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if snapshot?.connectionState == .authRequired {
                Button(action: reauthenticate) {
                    Image(systemName: "key")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                .help("\(profile.alias) 다시 로그인")
                .accessibilityLabel("\(profile.alias) 다시 로그인")
            } else {
                Button(action: makePrimary) {
                    Image(systemName: "star")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                .disabled(!profile.isEnabled)
                .help("\(profile.alias)을 대표 계정으로 설정")
                .accessibilityLabel("\(profile.alias)을 대표 계정으로 설정")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .accessibilityElement(children: .contain)
    }
}

private extension AccountUsageSnapshot {
    /// Buckets besides the main one, such as a model-scoped weekly limit.
    var extraBuckets: [RateLimitBucket] {
        rateLimitBuckets.filter { $0.limitId != primaryCodexBucket?.limitId }
    }

    var hasTokenSummary: Bool {
        tokenSummary.lifetimeTokens != nil || tokenSummary.latestDailyBucket?.tokens != nil || tokenSummary.peakDailyTokens != nil
    }

    var hasExtraDetails: Bool { !extraBuckets.isEmpty || hasTokenSummary }
}

private struct QuotaDetailsSection: View {
    let snapshot: AccountUsageSnapshot
    @Binding var isExpanded: Bool

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(spacing: 10) {
                ForEach(snapshot.extraBuckets) { bucket in
                    QuotaBucketCard(bucket: bucket)
                }
                if snapshot.hasTokenSummary {
                    TokenSummaryCard(summary: snapshot.tokenSummary)
                }
            }
            .padding(.top, 10)
        } label: {
            HStack {
                Label("추가 한도와 토큰", systemImage: "chart.xyaxis.line")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(snapshot.extraBuckets.isEmpty ? "토큰" : "\(snapshot.extraBuckets.count)개")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.20), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct QuotaBucketCard: View {
    let bucket: RateLimitBucket

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Text(bucket.displayName)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if bucket.spendControlReached == true {
                    Label("제한 도달", systemImage: "exclamationmark.octagon.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            if let primary = bucket.primary {
                QuotaWindowRow(title: quotaWindowTitle(primary), window: primary)
            }
            if let secondary = bucket.secondary {
                Divider()
                QuotaWindowRow(title: quotaWindowTitle(secondary), window: secondary)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.primary.opacity(0.06), lineWidth: 1)
        }
    }
}

private struct QuotaWindowRow: View {
    let title: String
    let window: RateLimitWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(window.remainingPercent)% 남음")
                    .font(.caption.weight(.semibold).monospacedDigit())
            }
            ProgressView(value: Double(window.remainingPercent), total: 100)
                .tint(usageColor(window.remainingPercent))
            HStack {
                Text(QuotaBarFormatters.windowText(window.windowDurationMinutes))
                Spacer()
                Text("초기화 \(QuotaBarFormatters.resetText(window.resetsAt))")
                    .lineLimit(1)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) 제한, \(window.remainingPercent)퍼센트 남음, 초기화 \(QuotaBarFormatters.resetText(window.resetsAt))")
    }
}

private struct TokenSummaryCard: View {
    let summary: TokenUsageSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("토큰 사용")
                .font(.subheadline.weight(.semibold))
            HStack(spacing: 0) {
                TokenMetric(
                    label: QuotaBarFormatters.dailyUsageLabel(for: summary.latestDailyBucket?.startDate),
                    value: summary.latestDailyBucket?.tokens
                )
                Divider().frame(height: 30)
                TokenMetric(label: "누적", value: summary.lifetimeTokens)
                Divider().frame(height: 30)
                TokenMetric(label: "최대 일간", value: summary.peakDailyTokens)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct TokenMetric: View {
    let label: String
    let value: Int64?

    var body: some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(QuotaBarFormatters.tokenText(value))
                .font(.subheadline.weight(.medium).monospacedDigit())
                .help(QuotaBarFormatters.fullTokenText(value))
        }
        .frame(maxWidth: .infinity)
    }
}

private struct SectionTitle: View {
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Spacer()
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 2)
    }
}

private struct StatusLabel: View {
    let snapshot: AccountUsageSnapshot?
    var compact = false

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusTint(snapshot))
                .frame(width: compact ? 6 : 7, height: compact ? 6 : 7)
            Text(snapshot?.connectionState.displayName ?? "대기 중")
                .lineLimit(1)
        }
        .font(compact ? .caption2 : .caption)
        .foregroundStyle(.secondary)
    }
}

private struct PlanBadge: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(tint.opacity(0.13), in: Capsule())
    }
}

extension AccountProvider {
    /// Service colour for badges and card tints: Claude's terracotta, Codex's ink.
    var tint: Color {
        switch self {
        case .codex: Color(nsColor: .labelColor)
        case .claude: Color(red: 0.80, green: 0.42, blue: 0.29)
        }
    }
}

private struct InlineNotice: View {
    let text: String
    let symbol: String
    let tint: Color
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(10)
        .background(tint.opacity(0.09), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

struct AddAccountView: View {
    @ObservedObject var store: UsageStore
    let onClose: () -> Void
    @State private var provider: AccountProvider = .codex
    @State private var alias = ""
    @State private var activeProfile: AccountProfile?
    @State private var login: AccountLogin?
    @State private var errorText: String?
    @State private var isStarting = false

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(
                title: "계정 연결",
                subtitle: login == nil ? "Codex 또는 Claude Code 계정을 QuotaBar에 추가합니다" : "브라우저에서 로그인을 완료하세요",
                symbol: "person.badge.plus",
                dismiss: login == nil && !isStarting ? onClose : nil
            )
            Divider()

            Group {
                if let login, let profile = activeProfile {
                    AccountLoginPanel(
                        store: store,
                        profile: profile,
                        login: login,
                        cancelTitle: "연결 취소",
                        cancel: { cancelLogin(profile: profile, login: login) }
                    )
                } else {
                    addAccountForm
                }
            }
            .padding(24)
        }
        .frame(width: 440)
        .background(Color(nsColor: .windowBackgroundColor))
        .interactiveDismissDisabled(login != nil)
    }

    private var addAccountForm: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 7) {
                Text("서비스")
                    .font(.subheadline.weight(.semibold))
                Picker("서비스", selection: $provider) {
                    ForEach(AccountProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("계정 이름")
                    .font(.subheadline.weight(.semibold))
                TextField(provider == .codex ? "예: 개인 Plus" : "예: 회사 Max", text: $alias)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { beginLogin() }
                Text("메뉴바와 계정 목록에만 표시되는 이름입니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Label {
                Text(provider == .codex
                    ? "계정마다 별도 로컬 프로필을 사용합니다. QuotaBar는 인증 파일 내용을 읽지 않습니다."
                    : "계정마다 별도 Claude Code 설정 폴더를 사용합니다. 로그인과 토큰 갱신은 Claude Code가 하고, QuotaBar는 사용량 조회에만 토큰을 씁니다.")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "lock.shield")
                    .foregroundStyle(.green)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(12)
            .background(.quaternary.opacity(0.24), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            if let errorText {
                Label(errorText, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("취소", role: .cancel, action: onClose)
                    .disabled(isStarting)
                Spacer()
                Button {
                    beginLogin()
                } label: {
                    if isStarting {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("로그인 계속", systemImage: "arrow.right")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isStarting)
            }
        }
    }

    private func beginLogin() {
        guard !isStarting, login == nil else { return }
        let cleanAlias = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanAlias.isEmpty else { return }
        isStarting = true
        errorText = nil
        Task {
            do {
                let result = try await store.addManagedAccount(alias: cleanAlias, provider: provider)
                activeProfile = result.0
                login = result.1
                openDeviceCodeBrowser(for: result.1)
                let completed = await store.waitForLogin(profile: result.0, loginID: result.1.loginID)
                if completed {
                    onClose()
                } else {
                    login = nil
                    errorText = store.snapshots[result.0.id]?.lastError ?? "로그인을 완료하지 못했습니다."
                }
            } catch {
                errorText = localizedMessage(error, fallback: "로그인을 시작하지 못했습니다.")
            }
            isStarting = false
        }
    }

    private func cancelLogin(profile: AccountProfile, login: AccountLogin) {
        Task {
            await store.cancelAndDiscardDeviceLogin(profile: profile, loginID: login.loginID)
            onClose()
        }
    }
}

struct ReauthenticateAccountView: View {
    @ObservedObject var store: UsageStore
    let profile: AccountProfile
    let onClose: () -> Void
    @State private var login: AccountLogin?
    @State private var errorText: String?
    @State private var isStarting = false

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(
                title: "다시 로그인",
                subtitle: profile.alias,
                symbol: "person.badge.key",
                dismiss: login == nil ? onClose : nil
            )
            Divider()

            Group {
                if let login {
                    AccountLoginPanel(
                        store: store,
                        profile: profile,
                        login: login,
                        cancelTitle: "로그인 취소",
                        cancel: { cancelLogin(login) }
                    )
                } else if isStarting {
                    VStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.large)
                        Text("안전한 로그인 준비 중…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 42)
                } else {
                    VStack(alignment: .leading, spacing: 18) {
                        Label(errorText ?? "로그인을 시작하지 못했습니다.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Button("닫기", role: .cancel, action: onClose)
                            Spacer()
                            Button("다시 시도") { startLogin() }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                }
            }
            .padding(24)
        }
        .frame(width: 440)
        .background(Color(nsColor: .windowBackgroundColor))
        .interactiveDismissDisabled(login != nil)
        .task { startLogin() }
    }

    private func startLogin() {
        guard !isStarting, login == nil else { return }
        isStarting = true
        errorText = nil
        Task {
            do {
                let nextLogin = try await store.beginReauthentication(profile: profile)
                login = nextLogin
                openDeviceCodeBrowser(for: nextLogin)
                let completed = await store.waitForLogin(profile: profile, loginID: nextLogin.loginID)
                if completed {
                    onClose()
                } else {
                    login = nil
                    errorText = store.snapshots[profile.id]?.lastError ?? "로그인을 완료하지 못했습니다."
                }
            } catch {
                errorText = localizedMessage(error, fallback: "로그인을 시작하지 못했습니다.")
            }
            isStarting = false
        }
    }

    private func cancelLogin(_ login: AccountLogin) {
        Task {
            await store.cancelReauthentication(profile: profile, loginID: login.loginID)
            onClose()
        }
    }
}

private struct SheetHeader: View {
    let title: String
    let subtitle: String
    let symbol: String
    let dismiss: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 36, height: 36)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let dismiss {
                Button(action: dismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("닫기")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }
}

/// Codex prints a device code for the browser; Claude Code opens its own browser login.
@MainActor
private func openDeviceCodeBrowser(for login: AccountLogin) {
    if case .deviceCode(let deviceLogin) = login {
        NSWorkspace.shared.open(deviceLogin.verificationURL)
    }
}

private struct AccountLoginPanel: View {
    @ObservedObject var store: UsageStore
    let profile: AccountProfile
    let login: AccountLogin
    let cancelTitle: String
    let cancel: () -> Void
    @State private var didCopyCode = false

    var body: some View {
        switch login {
        case .deviceCode(let deviceLogin):
            DeviceLoginPanel(
                accountName: profile.alias,
                login: deviceLogin,
                didCopyCode: $didCopyCode,
                cancelTitle: cancelTitle,
                cancel: cancel
            )
        case .claudeBrowser(let claudeLogin):
            ClaudeLoginPanel(
                accountName: profile.alias,
                login: claudeLogin,
                cancelTitle: cancelTitle,
                submitCode: { code in
                    Task { await store.submitClaudeLoginCode(profile: profile, loginID: claudeLogin.loginID, code: code) }
                },
                cancel: cancel
            )
        }
    }
}

private struct ClaudeLoginPanel: View {
    let accountName: String
    let login: ClaudeBrowserLogin
    let cancelTitle: String
    let submitCode: (String) -> Void
    let cancel: () -> Void
    @State private var code = ""
    @State private var didSubmitCode = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 11) {
                StepNumber(value: 1)
                VStack(alignment: .leading, spacing: 4) {
                    Text("브라우저에서 Claude 로그인")
                        .font(.subheadline.weight(.semibold))
                    Text("Claude Code가 브라우저를 엽니다. 사용할 계정이 \(accountName) 계정인지 확인하세요.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(alignment: .top, spacing: 11) {
                StepNumber(value: 2)
                VStack(alignment: .leading, spacing: 9) {
                    Text("코드가 표시되면 붙여넣기")
                        .font(.subheadline.weight(.semibold))
                    Text("브라우저에서 바로 완료되면 이 단계는 필요 없습니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        TextField("표시된 코드 전체", text: $code)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(submit)
                            // The CLI ignores a malformed code and keeps waiting, so allow a retry.
                            .onChange(of: code) { didSubmitCode = false }
                        Button(didSubmitCode ? "제출됨" : "제출", action: submit)
                            .buttonStyle(.bordered)
                            .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || didSubmitCode)
                    }
                }
            }

            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("로그인 완료를 기다리는 중입니다")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button(cancelTitle, role: .cancel, action: cancel)
                Spacer()
                if let url = login.authorizationURL {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        Label("브라우저 다시 열기", systemImage: "safari")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private func submit() {
        let clean = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !didSubmitCode else { return }
        didSubmitCode = true
        submitCode(clean)
    }
}

private struct DeviceLoginPanel: View {
    let accountName: String
    let login: DeviceCodeLogin
    @Binding var didCopyCode: Bool
    let cancelTitle: String
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 11) {
                StepNumber(value: 1)
                VStack(alignment: .leading, spacing: 4) {
                    Text("브라우저에서 ChatGPT 로그인")
                        .font(.subheadline.weight(.semibold))
                    Text("사용할 계정이 \(accountName) 계정인지 확인하세요.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(alignment: .top, spacing: 11) {
                StepNumber(value: 2)
                VStack(alignment: .leading, spacing: 9) {
                    Text("아래 코드 입력")
                        .font(.subheadline.weight(.semibold))
                    HStack(spacing: 12) {
                        Text(login.userCode)
                            .font(.system(.title2, design: .monospaced).weight(.bold))
                            .tracking(1.2)
                            .textSelection(.enabled)
                        Spacer()
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(login.userCode, forType: .string)
                            didCopyCode = true
                        } label: {
                            Label(didCopyCode ? "복사됨" : "복사", systemImage: didCopyCode ? "checkmark" : "doc.on.doc")
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(14)
                    .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                }
            }

            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("로그인 완료를 기다리는 중입니다")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button(cancelTitle, role: .cancel, action: cancel)
                Spacer()
                Button {
                    NSWorkspace.shared.open(login.verificationURL)
                } label: {
                    Label("브라우저 다시 열기", systemImage: "safari")
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

}

private struct StepNumber: View {
    let value: Int

    var body: some View {
        Text("\(value)")
            .font(.caption.weight(.bold))
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(Color.accentColor, in: Circle())
            .accessibilityLabel("\(value)단계")
    }
}

struct SettingsView: View {
    @ObservedObject var store: UsageStore
    @Environment(\.dismiss) private var dismiss
    @State private var selection: SettingsPage = .accounts
    @State private var deletionCandidate: AccountProfile?
    @State private var presentsAddAccount = false
    @State private var reauthenticationProfile: AccountProfile?

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(selection: $selection)
                .frame(width: 176)

            Divider()

            VStack(spacing: 0) {
                SettingsHeader(page: selection, dismiss: { dismiss() })
                Divider()
                ScrollView {
                    Group {
                        switch selection {
                        case .accounts:
                            AccountsSettingsPage(
                                store: store,
                                deletionCandidate: $deletionCandidate,
                                addAccount: { presentsAddAccount = true },
                                reauthenticate: { reauthenticationProfile = $0 }
                            )
                        case .general:
                            GeneralSettingsPage(store: store)
                        }
                    }
                    .padding(24)
                }
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(width: 720, height: 570)
        .sheet(isPresented: $presentsAddAccount) {
            AddAccountView(store: store, onClose: { presentsAddAccount = false })
        }
        .sheet(item: $reauthenticationProfile) { profile in
            ReauthenticateAccountView(
                store: store,
                profile: profile,
                onClose: { reauthenticationProfile = nil }
            )
        }
        .confirmationDialog("계정을 제거할까요?", isPresented: Binding(
            get: { deletionCandidate != nil },
            set: { if !$0 { deletionCandidate = nil } }
        )) {
            if let profile = deletionCandidate {
                Button("목록에서만 제거", role: .destructive) { remove(profile, deleteFiles: false) }
                if profile.isManagedByApp {
                    Button("로그아웃 후 로컬 프로필 삭제", role: .destructive) { remove(profile, deleteFiles: true) }
                }
            }
            Button("취소", role: .cancel) {}
        } message: {
            if let profile = deletionCandidate {
                Text(profile.isManagedByApp
                    ? "두 번째 옵션은 이 계정에서 로그아웃하고 앱이 만든 로컬 프로필만 삭제합니다. 외부 프로필은 건드리지 않습니다."
                    : "외부 프로필의 폴더와 인증 파일은 삭제하지 않습니다.")
            }
        }
    }

    private func remove(_ profile: AccountProfile, deleteFiles: Bool) {
        Task {
            do {
                try await store.remove(profile, deleteManagedFiles: deleteFiles)
            } catch {
                store.transientMessage = "계정을 제거하지 못했습니다. \(localizedMessage(error, fallback: ""))"
            }
        }
    }
}

private enum SettingsPage: String, CaseIterable, Identifiable {
    case accounts
    case general

    var id: String { rawValue }
    var title: String {
        switch self {
        case .accounts: "계정"
        case .general: "일반"
        }
    }
    var symbol: String {
        switch self {
        case .accounts: "person.2"
        case .general: "gearshape"
        }
    }
    var subtitle: String {
        switch self {
        case .accounts: "연결된 계정과 대표 계정을 관리합니다."
        case .general: "Codex 실행 파일과 시작 동작을 설정합니다."
        }
    }
}

private struct SettingsSidebar: View {
    @Binding var selection: SettingsPage

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("QuotaBar")
                .font(.headline)
                .padding(.horizontal, 10)
                .padding(.bottom, 8)

            ForEach(SettingsPage.allCases) { page in
                Button {
                    selection = page
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: page.symbol)
                            .frame(width: 18)
                        Text(page.title)
                        Spacer(minLength: 0)
                    }
                    .font(.subheadline.weight(selection == page ? .semibold : .regular))
                    .foregroundStyle(selection == page ? Color.accentColor : Color.primary)
                    .padding(.horizontal, 10)
                    .frame(height: 34)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Spacer()

            Text("QuotaBar \(AppInfo.version)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 10)
                .padding(.bottom, 4)
        }
        .padding(.horizontal, 8)
        .padding(.top, 14)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

private struct SettingsHeader: View {
    let page: SettingsPage
    let dismiss: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(page.title)
                    .font(.title2.weight(.semibold))
                Text(page.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("완료", action: dismiss)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 17)
    }
}

private struct AccountsSettingsPage: View {
    @ObservedObject var store: UsageStore
    @Binding var deletionCandidate: AccountProfile?
    let addAccount: () -> Void
    let reauthenticate: (AccountProfile) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Button(action: addAccount) {
                    Label("계정 연결", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)

                ForEach(AccountProvider.allCases) { provider in
                    let label = store.defaultHomeLabel(for: provider)
                    let isRegistered = store.hasDefaultProfile(for: provider)
                    Button {
                        store.addDefaultProfile(for: provider)
                    } label: {
                        Label("기본 \(label) 사용", systemImage: "terminal")
                    }
                    .buttonStyle(.bordered)
                    .disabled(isRegistered)
                    .help(isRegistered
                        ? "기본 \(label) 프로필이 이미 등록되어 있습니다"
                        : "기존 \(provider.displayName) CLI 로그인을 연결합니다")
                }
            }

            if store.profiles.isEmpty {
                ContentUnavailableView(
                    "연결된 계정 없음",
                    systemImage: "person.crop.circle.badge.plus",
                    description: Text("계정을 연결하면 남은 쿼터와 초기화 시각을 확인할 수 있습니다.")
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 46)
            } else {
                VStack(spacing: 12) {
                    ForEach(store.profiles) { profile in
                        AccountSettingsRow(
                            profile: profile,
                            snapshot: store.snapshots[profile.id],
                            isPrimary: profile.id == store.primaryProfile?.id,
                            isEnabled: Binding(
                                get: { store.profiles.first(where: { $0.id == profile.id })?.isEnabled ?? false },
                                set: { store.setEnabled(profile.id, enabled: $0) }
                            ),
                            rename: { store.rename(profile.id, to: $0) },
                            makePrimary: { store.makePrimary(profile.id) },
                            reauthenticate: { reauthenticate(profile) },
                            remove: { deletionCandidate = profile }
                        )
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AccountSettingsRow: View {
    let profile: AccountProfile
    let snapshot: AccountUsageSnapshot?
    let isPrimary: Bool
    @Binding var isEnabled: Bool
    let rename: (String) -> Void
    let makePrimary: () -> Void
    let reauthenticate: () -> Void
    let remove: () -> Void
    @State private var draftAlias: String
    @FocusState private var aliasIsFocused: Bool

    init(
        profile: AccountProfile,
        snapshot: AccountUsageSnapshot?,
        isPrimary: Bool,
        isEnabled: Binding<Bool>,
        rename: @escaping (String) -> Void,
        makePrimary: @escaping () -> Void,
        reauthenticate: @escaping () -> Void,
        remove: @escaping () -> Void
    ) {
        self.profile = profile
        self.snapshot = snapshot
        self.isPrimary = isPrimary
        _isEnabled = isEnabled
        self.rename = rename
        self.makePrimary = makePrimary
        self.reauthenticate = reauthenticate
        self.remove = remove
        _draftAlias = State(initialValue: profile.alias)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .top, spacing: 12) {
                AccountAvatar(provider: profile.provider, snapshot: snapshot, size: 38)

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 7) {
                        TextField("계정 이름", text: $draftAlias)
                            .textFieldStyle(.plain)
                            .font(.subheadline.weight(.semibold))
                            .focused($aliasIsFocused)
                            .onSubmit(commitAlias)
                        if isPrimary {
                            SettingsPill(text: "대표", tint: .yellow)
                        }
                        SettingsPill(text: planBadgeText(profile: profile, snapshot: snapshot), tint: profile.provider.tint)
                        SettingsPill(text: profile.isManagedByApp ? "앱 관리" : "외부", tint: .secondary)
                    }

                    if let email = snapshot?.identity.email {
                        Text(email)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    if !limitRows(snapshot).isEmpty {
                        MiniLimits(snapshot: snapshot)
                    }

                    Text(snapshot?.lastError ?? statusDetail)
                        .font(.caption)
                        .foregroundStyle(snapshot?.lastError == nil ? Color.secondary : Color.orange)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 7) {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(snapshot?.remainingPercent.map { "\($0)%" } ?? "—")
                            .font(.title3.weight(.semibold).monospacedDigit())
                            .foregroundStyle(usageColor(snapshot?.remainingPercent))
                        if let window = snapshot?.limitingWindow {
                            Text(QuotaBarFormatters.windowLabel(window.windowDurationMinutes))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Toggle("활성", isOn: $isEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .controlSize(.small)
                        .accessibilityLabel("\(profile.alias) 활성화")
                }
            }

            HStack(spacing: 9) {
                if isPrimary {
                    Label("대표 계정", systemImage: "star.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                } else {
                    Button(action: makePrimary) {
                        Label("대표로 설정", systemImage: "star")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!isEnabled)
                }

                if snapshot?.connectionState == .authRequired {
                    Button(action: reauthenticate) {
                        Label("다시 로그인", systemImage: "key")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }

                Spacer()

                Menu {
                    if snapshot?.connectionState != .authRequired {
                        Button(action: reauthenticate) {
                            Label("다시 로그인", systemImage: "person.badge.key")
                        }
                    }
                    Divider()
                    Button(role: .destructive, action: remove) {
                        Label("계정 제거", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 24, height: 22)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel("\(profile.alias) 계정 메뉴")
            }
        }
        .padding(15)
        .background(.quaternary.opacity(0.20), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(statusTint(snapshot))
                .frame(width: 3)
                .padding(.vertical, 11)
        }
        .onChange(of: aliasIsFocused) { _, isFocused in
            if !isFocused { commitAlias() }
        }
        .onChange(of: profile.alias) { _, newAlias in
            if !aliasIsFocused { draftAlias = newAlias }
        }
    }

    private var statusDetail: String {
        let status = snapshot?.connectionState.displayName ?? "대기 중"
        let fetched = QuotaBarFormatters.fetchedText(snapshot?.fetchedAt)
        return "\(status) · \(fetched) 갱신"
    }

    private func commitAlias() {
        let clean = draftAlias.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty {
            draftAlias = profile.alias
        } else {
            draftAlias = clean
            rename(clean)
        }
    }
}

private struct GeneralSettingsPage: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsGroup(title: "Codex") {
                HStack(spacing: 12) {
                    SettingsIcon(symbol: "terminal", tint: .blue)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("실행 파일")
                            .font(.subheadline.weight(.medium))
                        Text(store.preferences.customCodexExecutablePath?.path ?? "ChatGPT 앱 또는 PATH에서 자동으로 찾습니다")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                    Spacer(minLength: 12)
                    if store.preferences.customCodexExecutablePath != nil {
                        Button("자동 찾기") { store.setCodexExecutablePath(nil) }
                            .buttonStyle(.borderless)
                    }
                    Button("선택…", action: chooseExecutable)
                }
            }

            SettingsGroup(title: "시작") {
                HStack(spacing: 12) {
                    SettingsIcon(symbol: "power", tint: .green)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("로그인 시 자동 실행")
                            .font(.subheadline.weight(.medium))
                        Text("Mac에 로그인하면 QuotaBar를 메뉴바에서 시작합니다.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("로그인 시 QuotaBar 실행", isOn: Binding(
                        get: { store.preferences.launchAtLogin },
                        set: { store.setLaunchAtLogin($0) }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                }
            }

            HStack(alignment: .top, spacing: 11) {
                Image(systemName: "lock.shield.fill")
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 4) {
                    Text("인증 정보는 Mac에만 보관됩니다")
                        .font(.subheadline.weight(.medium))
                    Text("로그인은 로컬 Codex와 Claude Code가 직접 처리합니다. Codex 인증 파일은 읽지 않습니다. Claude Code 계정은 Keychain의 액세스 토큰을 메모리로만 읽어 Anthropic 사용량 API에만 보냅니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
            .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func chooseExecutable() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.message = "codex 실행 파일을 선택하세요"
        if panel.runModal() == .OK {
            store.setCodexExecutablePath(panel.url)
        }
    }
}

private struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 2)
            content
                .padding(15)
                .background(.quaternary.opacity(0.20), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}

/// The service logo with the account's connection state as a small corner badge, so
/// accounts with the same name can still be told apart at a glance.
private struct AccountAvatar: View {
    let provider: AccountProvider
    let snapshot: AccountUsageSnapshot?
    let size: CGFloat

    var body: some View {
        ProviderLogo(provider: provider, size: size)
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: statusSymbol(snapshot))
                    .font(.system(size: size * 0.17, weight: .heavy))
                    .foregroundStyle(.white)
                    .frame(width: size * 0.36, height: size * 0.36)
                    .background(statusTint(snapshot), in: Circle())
                    .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                    .offset(x: size * 0.06, y: size * 0.06)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(provider.displayName), \(snapshot?.connectionState.displayName ?? "대기 중")")
    }
}

private struct ProviderLogo: View {
    let provider: AccountProvider
    let size: CGFloat

    var body: some View {
        Image(nsImage: Self.mark(for: provider))
            .renderingMode(.template)
            .resizable()
            .interpolation(.high)
            .foregroundStyle(.white)
            .padding(size * (provider == .codex ? 0.2 : 0.16))
            .frame(width: size, height: size)
            .background(background, in: Circle())
            .overlay(Circle().strokeBorder(.white.opacity(0.12), lineWidth: 1))
    }

    private var background: Color {
        switch provider {
        case .codex: Color(red: 0.07, green: 0.07, blue: 0.08)
        case .claude: Color(red: 0.85, green: 0.47, blue: 0.34)
        }
    }

    private static func mark(for provider: AccountProvider) -> NSImage {
        switch provider {
        case .codex: codexMark
        case .claude: claudeMark
        }
    }

    private static let codexMark = template(svg: """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="1.85 1.6 16.6 16.8">
          <path fill="#000" d="M11.248 18.25q-.825 0-1.568-.314a4.3 4.3 0 0 1-1.32-.874 4 4 0 0 1-1.304.214 4 4 0 0 1-2.046-.544 4.27 4.27 0 0 1-1.518-1.485 4 4 0 0 1-.56-2.095q0-.48.131-1.04A4.4 4.4 0 0 1 2.04 10.71a4.07 4.07 0 0 1 .017-3.4 4.2 4.2 0 0 1 1.056-1.418 3.8 3.8 0 0 1 1.6-.842 3.9 3.9 0 0 1 .76-1.683q.593-.759 1.451-1.188a4.04 4.04 0 0 1 1.832-.429q.825 0 1.567.313.742.314 1.32.875a4 4 0 0 1 1.304-.215q1.106 0 2.046.545a4.14 4.14 0 0 1 1.501 1.485q.578.941.578 2.095 0 .48-.132 1.04.66.61 1.023 1.419.363.792.363 1.666 0 .892-.38 1.717a4.3 4.3 0 0 1-1.072 1.435 3.8 3.8 0 0 1-1.584.825 3.8 3.8 0 0 1-.775 1.683 4.06 4.06 0 0 1-1.436 1.188 4.04 4.04 0 0 1-1.832.429m-4.076-2.062q.825 0 1.435-.347l3.103-1.782a.36.36 0 0 0 .164-.313v-1.42L7.881 14.62a.67.67 0 0 1-.726 0l-3.118-1.798a.5.5 0 0 1-.017.115v.198q0 .841.396 1.551.413.693 1.139 1.089a3.2 3.2 0 0 0 1.617.412m.165-2.69a.4.4 0 0 0 .181.05q.083 0 .165-.05l1.238-.71-3.977-2.31a.7.7 0 0 1-.363-.643v-3.58q-.825.362-1.32 1.122a2.9 2.9 0 0 0-.495 1.65q0 .809.413 1.55.412.743 1.072 1.123zm3.91 3.663q.875 0 1.585-.396a2.96 2.96 0 0 0 1.534-2.64v-3.564a.32.32 0 0 0-.165-.297l-1.254-.726v4.604a.7.7 0 0 1-.363.643l-3.119 1.799a3 3 0 0 0 1.783.577m.627-6.039V8.878L10.01 7.822 8.129 8.878v2.244l1.881 1.056zM7.057 5.859a.7.7 0 0 1 .363-.644l3.119-1.798a3 3 0 0 0-1.782-.578q-.874 0-1.584.396A2.96 2.96 0 0 0 6.05 4.324a3.07 3.07 0 0 0-.396 1.551v3.547q0 .199.165.314l1.237.726zm8.383 7.887q.825-.364 1.303-1.123.495-.758.495-1.65a3.15 3.15 0 0 0-.412-1.55q-.413-.743-1.073-1.123l-3.086-1.782q-.099-.065-.181-.049a.3.3 0 0 0-.165.05l-1.238.692 3.993 2.327a.6.6 0 0 1 .264.264.64.64 0 0 1 .1.363zm-3.317-8.382a.63.63 0 0 1 .726 0l3.135 1.831v-.297q0-.792-.396-1.501a2.86 2.86 0 0 0-1.105-1.155q-.71-.43-1.65-.43-.825 0-1.436.347L8.294 5.941a.36.36 0 0 0-.165.314v1.418z"/>
        </svg>
        """, fallback: "chevron.left.forwardslash.chevron.right")

    private static let claudeMark = template(svg: """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">
          <circle cx="12" cy="12" r="2.6" fill="#000"/>
          <g stroke="#000" stroke-width="1.9" stroke-linecap="round">
          <line x1="14.19" y1="11.81" x2="21.36" y2="11.18"/>
          <line x1="13.73" y1="10.65" x2="18.38" y2="7.01"/>
          <line x1="13.00" y1="10.04" x2="16.09" y2="3.98"/>
          <line x1="11.73" y1="9.82" x2="11.06" y2="4.36"/>
          <line x1="10.83" y1="10.13" x2="6.91" y2="3.86"/>
          <line x1="9.99" y1="11.11" x2="4.69" y2="8.75"/>
          <line x1="9.81" y1="12.15" x2="2.82" y2="12.64"/>
          <line x1="10.27" y1="13.35" x2="6.01" y2="16.68"/>
          <line x1="11.00" y1="13.96" x2="7.69" y2="20.46"/>
          <line x1="12.23" y1="14.19" x2="12.87" y2="20.25"/>
          <line x1="13.32" y1="13.76" x2="17.30" y2="19.03"/>
          <line x1="13.98" y1="12.96" x2="19.10" y2="15.46"/>
          </g>
        </svg>
        """, fallback: "asterisk")

    private static func template(svg: String, fallback: String) -> NSImage {
        let image = NSImage(data: Data(svg.utf8))
            ?? NSImage(systemSymbolName: fallback, accessibilityDescription: nil)
            ?? NSImage()
        image.isTemplate = true
        return image
    }
}

private struct SettingsIcon: View {
    let symbol: String
    let tint: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 34, height: 34)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

private struct SettingsPill: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint == .secondary ? Color.secondary : Color.primary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(tint.opacity(tint == .secondary ? 0.10 : 0.20), in: Capsule())
    }
}

private func planBadgeText(profile: AccountProfile, snapshot: AccountUsageSnapshot?) -> String {
    guard let planName = snapshot?.identity.planName else { return profile.provider.shortName }
    return "\(profile.provider.shortName) \(planName)"
}

/// Shown instead of the limit bars when the account has nothing current to show.
private func rowStatusText(profile: AccountProfile, snapshot: AccountUsageSnapshot?) -> String? {
    guard profile.isEnabled else { return "갱신 중지됨" }
    if snapshot?.connectionState == .authRequired { return "로그인 필요" }
    if limitRows(snapshot).isEmpty { return snapshot?.connectionState.displayName ?? "사용량 없음" }
    return nil
}

private func resetLine(_ window: RateLimitWindow) -> String {
    let countdown = QuotaBarFormatters.resetCountdown(window.resetsAt)
    guard window.resetsAt != nil, let clock = QuotaBarFormatters.resetClock(window.resetsAt) else { return countdown }
    return "\(countdown) 초기화 · \(clock)"
}

private func windowResetSummary(_ snapshot: AccountUsageSnapshot?) -> String? {
    let windows = snapshot?.displayWindows ?? []
    guard !windows.isEmpty else { return nil }
    return windows
        .map { "\(QuotaBarFormatters.windowLabel($0.windowDurationMinutes)) \($0.remainingPercent)% · \(resetLine($0))" }
        .joined(separator: "\n")
}

private func remainingAccessibilityText(_ remaining: Int?, window: RateLimitWindow?) -> String {
    if let remaining { return "\(quotaWindowTitle(window)) 잔여 \(remaining)퍼센트" }
    return "쿼터 정보 없음"
}

private func quotaWindowTitle(_ window: RateLimitWindow?) -> String {
    guard let minutes = window?.windowDurationMinutes, minutes > 0 else { return "사용량 한도" }
    return "\(QuotaBarFormatters.windowText(minutes)) 한도"
}

private func usageColor(_ remaining: Int?) -> Color {
    guard let remaining else { return .secondary }
    switch remaining {
    case 0...20: return .red
    case 21...50: return .orange
    default: return .green
    }
}

private func statusTint(_ snapshot: AccountUsageSnapshot?) -> Color {
    switch snapshot?.connectionState {
    case .ready: return .green
    case .authRequired, .error: return .red
    case .stale: return .orange
    case .refreshing, .authenticating, .starting: return .blue
    default: return .secondary
    }
}

private func statusSymbol(_ snapshot: AccountUsageSnapshot?) -> String {
    switch snapshot?.connectionState {
    case .ready: return "checkmark"
    case .authRequired: return "key.slash"
    case .error, .stale: return "exclamationmark"
    case .refreshing: return "arrow.clockwise"
    case .authenticating: return "key"
    case .starting: return "ellipsis"
    default: return "circle"
    }
}

private func localizedMessage(_ error: Error, fallback: String) -> String {
    (error as? LocalizedError)?.errorDescription ?? fallback
}
