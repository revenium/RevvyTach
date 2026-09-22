//
//  DebugNetworkLogView.swift
//  Claude Usage
//
//  Created by Claude on 2026-01-29.
//

import AppKit
import Combine
import SwiftUI
import UsageCore

struct ProviderDiagnosticRequestIdentity: Hashable {
    let profileID: UUID?
    let providerRevision: UInt64?

    init(profile: Profile?) {
        profileID = profile?.id
        providerRevision = profile?.providerRevision
    }
}

@MainActor
final class ProviderDiagnosticsPresentationModel: ObservableObject {
    typealias Snapshotter =
        @MainActor (Profile?) async -> ProviderDiagnosticSnapshot

    @Published private(set) var snapshot:
        ProviderDiagnosticSnapshot?
    @Published private(set) var isRefreshing = false

    private let snapshotter: Snapshotter
    private var latestRequestGeneration: UUID?

    init(
        snapshotter: @escaping Snapshotter = {
            await ProviderDiagnosticsService.shared.snapshot(for: $0)
        }
    ) {
        self.snapshotter = snapshotter
    }

    func refresh(for profile: Profile?) async {
        let generation = UUID()
        latestRequestGeneration = generation
        snapshot = nil
        isRefreshing = true
        defer {
            if latestRequestGeneration == generation {
                isRefreshing = false
            }
        }

        let candidate = await snapshotter(profile)
        guard !Task.isCancelled,
              latestRequestGeneration == generation else {
            return
        }
        snapshot = candidate
    }
}

struct DebugNetworkLogView: View {
    @StateObject private var loggerService = NetworkLoggerService.shared
    @StateObject private var profileManager = ProfileManager.shared
    @StateObject private var diagnostics =
        ProviderDiagnosticsPresentationModel()
    @State private var selectedDuration: LoggingDuration = .fifteenMinutes
    @State private var selectedLog: NetworkRequestLog?
    @State private var showClearConfirmation = false
    @State private var currentTime = Date()

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.section) {
                // Header
                SettingsPageHeader(
                    title: "debug.title".localized,
                    subtitle: "debug.subtitle".localized
                )

                ProviderDiagnosticsCard(
                    snapshot: diagnostics.snapshot,
                    isRefreshing: diagnostics.isRefreshing,
                    onRefresh: {
                        let profile = profileManager.activeProfile
                        Task {
                            await diagnostics.refresh(for: profile)
                        }
                    },
                    onCopy: copyDiagnostics
                )

                // Controls Card
                SettingsSectionCard(
                    title: "debug.network_logger".localized,
                    subtitle: "debug.network_logger_desc".localized
                ) {
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.cardPadding) {
                        if loggerService.storageFailure
                            == .unsafeLegacyCaptureRetained {
                            unsafeLegacyCaptureWarning

                            Divider()
                        }

                        // Duration Picker
                        VStack(alignment: .leading, spacing: DesignTokens.Spacing.small) {
                            Text("debug.logging_duration".localized)
                                .font(DesignTokens.Typography.bodyMedium)

                            Picker("", selection: $selectedDuration) {
                                ForEach(LoggingDuration.allCases) { duration in
                                    Text(duration.displayName).tag(duration)
                                }
                            }
                            .pickerStyle(.segmented)
                            .disabled(
                                loggerService.session.isActive
                                    || loggerService.storageFailure != nil
                            )
                        }

                        Divider()

                        // Status Indicator
                        HStack(spacing: DesignTokens.Spacing.iconText) {
                            SettingsStatusGlyph(
                                kind: loggerService.session.isActive ? .ok : .inactive
                            )

                            if loggerService.session.isActive {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("debug.logging_active".localized)
                                        .font(DesignTokens.Typography.bodyMedium)
                                        .foregroundColor(SettingsColors.success)

                                    if let remaining = loggerService.remainingTime {
                                        Text(String(format: "debug.stops_in".localized, formatTimeRemaining(remaining)))
                                            .font(DesignTokens.Typography.caption)
                                            .foregroundColor(SettingsColors.secondary)
                                    }
                                }
                            } else {
                                Text("debug.logging_inactive".localized)
                                    .font(DesignTokens.Typography.bodyMedium)
                                    .foregroundColor(SettingsColors.secondary)
                            }

                            Spacer()
                        }

                        Divider()

                        // Action Buttons
                        HStack(spacing: DesignTokens.Spacing.medium) {
                            if loggerService.session.isActive {
                                SettingsButton(
                                    title: "debug.stop_logging".localized,
                                    icon: "stop.fill",
                                    style: .destructive
                                ) {
                                    loggerService.stopLogging()
                                }
                                .disabled(
                                    loggerService.storageFailure != nil
                                )
                            } else {
                                SettingsButton(
                                    title: "debug.start_logging".localized,
                                    icon: "play.fill",
                                    style: .primary
                                ) {
                                    loggerService.startLogging(duration: selectedDuration.rawValue)
                                }
                                .disabled(
                                    loggerService.storageFailure != nil
                                )
                            }

                            SettingsButton(
                                title: "debug.clear_logs".localized,
                                icon: "trash"
                            ) {
                                showClearConfirmation = true
                            }
                            .disabled(
                                loggerService.session.logs.isEmpty
                                    || loggerService.storageFailure != nil
                            )
                        }
                    }
                }
                .alert("debug.clear_all_logs".localized, isPresented: $showClearConfirmation) {
                    Button("common.cancel".localized, role: .cancel) { }
                    Button("debug.clear_logs".localized, role: .destructive) {
                        loggerService.clearLogs()
                    }
                } message: {
                    Text("debug.clear_logs_message".localized)
                }

                // Logs List Card
                SettingsSectionCard(
                    title: "debug.captured_requests".localized,
                    subtitle: String(format: "debug.requests_logged".localized, loggerService.session.logs.count)
                ) {
                    if loggerService.storageFailure
                        == .unsafeLegacyCaptureRetained {
                        Text(
                            ProviderUILocalization.text(
                                "diagnostics.network_logs.cleanup_required",
                                fallback:
                                    "Network logs are unavailable until "
                                    + "secure cleanup succeeds."
                            )
                        )
                            .font(DesignTokens.Typography.body)
                            .foregroundColor(SettingsColors.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, DesignTokens.Spacing.cardPadding)
                    } else if loggerService.session.logs.isEmpty {
                        Text("debug.no_requests".localized)
                            .font(DesignTokens.Typography.body)
                            .foregroundColor(SettingsColors.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, DesignTokens.Spacing.cardPadding)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(loggerService.session.logs.reversed()) { log in
                                NetworkLogRow(log: log) {
                                    selectedLog = log
                                }

                                if log.id != loggerService.session.logs.first?.id {
                                    Divider()
                                }
                            }
                        }
                    }
                }

                Spacer()
            }
            .padding()
        }
        .sheet(item: $selectedLog) { log in
            NetworkLogDetailView(log: log)
        }
        .onReceive(timer) { _ in
            currentTime = Date()
        }
        .task(
            id: ProviderDiagnosticRequestIdentity(
                profile: profileManager.activeProfile
            )
        ) {
            let profile = profileManager.activeProfile
            await diagnostics.refresh(for: profile)
        }
    }

    private func formatTimeRemaining(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds) / 60
        let secs = Int(seconds) % 60

        if minutes > 0 {
            return "\(minutes)m \(secs)s"
        } else {
            return "\(secs)s"
        }
    }

    private var unsafeLegacyCaptureWarning: some View {
        SettingsStatusBanner(tone: .error, icon: "exclamationmark.triangle.fill") {
            VStack(
                alignment: .leading,
                spacing: DesignTokens.Spacing.small
            ) {
                Text(
                    ProviderUILocalization.text(
                        "diagnostics.network_logs.cleanup_title",
                        fallback: "Secure Cleanup Required"
                    )
                )
                .font(DesignTokens.Typography.bodyMedium)

                Text(
                    ProviderUILocalization.text(
                        "diagnostics.network_logs.cleanup_message",
                        fallback:
                            "A legacy network capture may contain "
                            + "credentials and could not be safely "
                            + "removed. Network logging is blocked "
                            + "until cleanup succeeds."
                    )
                )
                .font(DesignTokens.Typography.body)
                .foregroundColor(SettingsColors.secondary)

                SettingsButton(
                    title: ProviderUILocalization.text(
                        "diagnostics.network_logs.retry_cleanup",
                        fallback: "Retry Secure Cleanup"
                    ),
                    icon: "arrow.clockwise",
                    style: .destructive
                ) {
                    loggerService.retryUnsafeLegacyCaptureCleanup()
                }
            }
        }
    }

    private func copyDiagnostics() {
        guard let diagnosticSnapshot = diagnostics.snapshot else {
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(
            diagnosticSnapshot.supportText,
            forType: .string
        )
    }
}

// MARK: - Safe Provider Diagnostics

private struct ProviderDiagnosticsCard: View {
    let snapshot: ProviderDiagnosticSnapshot?
    let isRefreshing: Bool
    let onRefresh: () -> Void
    let onCopy: () -> Void

    var body: some View {
        SettingsSectionCard(
            title: text(
                "diagnostics.provider.title",
                "Provider Diagnostics"
            ),
            subtitle: text(
                "diagnostics.provider.subtitle",
                "Copy a redacted status summary for troubleshooting."
            )
        ) {
            VStack(
                alignment: .leading,
                spacing: DesignTokens.Spacing.medium
            ) {
                if let snapshot {
                    diagnosticRows(snapshot)
                } else {
                    HStack {
                        ProgressView()
                            .controlSize(.small)
                        Text(
                            text(
                                "diagnostics.provider.loading",
                                "Checking provider status…"
                            )
                        )
                        .foregroundColor(SettingsColors.secondary)
                    }
                }

                Divider()

                HStack(spacing: DesignTokens.Spacing.medium) {
                    SettingsButton(
                        title: text(
                            "diagnostics.provider.refresh",
                            "Refresh Diagnostics"
                        ),
                        icon: "arrow.clockwise"
                    ) {
                        onRefresh()
                    }
                    .disabled(isRefreshing)

                    SettingsButton(
                        title: text(
                            "diagnostics.provider.copy",
                            "Copy Redacted Diagnostics"
                        ),
                        icon: "doc.on.doc"
                    ) {
                        onCopy()
                    }
                    .disabled(snapshot == nil)

                    if isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func diagnosticRows(
        _ snapshot: ProviderDiagnosticSnapshot
    ) -> some View {
        VStack(spacing: 8) {
            diagnosticRow(
                label: text(
                    "diagnostics.provider.app",
                    "App"
                ),
                value: "\(snapshot.appVersion) "
                    + "(\(snapshot.appBuild ?? "unknown"))"
            )
            diagnosticRow(
                label: text(
                    "diagnostics.provider.os",
                    "macOS"
                ),
                value: snapshot.osVersion
            )
            diagnosticRow(
                label: text(
                    "diagnostics.provider.provider",
                    "Provider"
                ),
                value: snapshot.providerID
            )
            if snapshot.providerID == "codex" {
                diagnosticRow(
                    label: text(
                        "diagnostics.provider.codex",
                        "Codex"
                    ),
                    value:
                        snapshot.codexVersion
                        ?? snapshot.codexExecutableStatus.rawValue
                )
                diagnosticRow(
                    label: text(
                        "diagnostics.provider.app_server",
                        "App Server"
                    ),
                    value: snapshot.appServerCapability.rawValue
                )
                diagnosticRow(
                    label: text(
                        "diagnostics.provider.home",
                        "Codex Home"
                    ),
                    value: snapshot.homeFingerprint ?? "not linked"
                )
            }
            diagnosticRow(
                label: text(
                    "diagnostics.provider.health",
                    "Health"
                ),
                value: snapshot.health?.status.rawValue
                    ?? "not checked"
            )
            if let duration =
                snapshot.requestDurationMilliseconds {
                diagnosticRow(
                    label: text(
                        "diagnostics.provider.duration",
                        "Check Duration"
                    ),
                    value: "\(duration) ms"
                )
            }
        }
    }

    private func diagnosticRow(
        label: String,
        value: String
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(DesignTokens.Typography.caption)
                .foregroundColor(SettingsColors.secondary)
                .frame(width: 110, alignment: .leading)

            Text(SensitiveDataRedactor.redact(value))
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func text(_ key: String, _ fallback: String) -> String {
        ProviderUILocalization.text(key, fallback: fallback)
    }
}

// MARK: - Log Row

struct NetworkLogRow: View {
    let log: NetworkRequestLog
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: DesignTokens.Spacing.medium) {
                // Status indicator
                SettingsStatusGlyph(kind: statusKind, size: 10)

                // Main content
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        // Method badge
                        SettingsBadge(
                            text: log.method,
                            tone: methodTone,
                            font: .system(size: 10, weight: .medium, design: .monospaced)
                        )

                        // Status code
                        if let status = log.statusCode {
                            Text("\(status)")
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundColor(SettingsColors.secondary)
                        }

                        // Duration
                        if let duration = log.duration {
                            Text(String(format: "%.2fs", duration))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(SettingsColors.secondary)
                        }

                        Spacer()

                        // Timestamp
                        Text(formatTime(log.timestamp))
                            .font(DesignTokens.Typography.caption)
                            .foregroundColor(SettingsColors.secondary)
                    }

                    // URL
                    Text(log.url)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 10))
                    .foregroundColor(SettingsColors.secondary)
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var statusKind: SettingsStatusGlyph.Kind {
        if let status = log.statusCode {
            switch status {
            case 200..<300: return .ok
            case 400..<500: return .warning
            case 500...: return .error
            default: return .inactive
            }
        }
        return log.errorMessage != nil ? .error : .inactive
    }

    private var methodTone: SettingsTone {
        switch log.method {
        case "GET": return .info
        case "POST": return .success
        case "PUT": return .warning
        case "DELETE": return .error
        default: return .neutral
        }
    }

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }
}

// MARK: - Log Detail View

struct NetworkLogDetailView: View {
    let log: NetworkRequestLog
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("debug.request_details".localized)
                    .font(.system(size: 16, weight: .semibold))

                Spacer()

                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(SettingsColors.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()

            Divider()

            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Basic Info
                    DetailSection(title: "debug.basic_information".localized) {
                        DetailRow(label: "debug.url".localized, value: log.url)
                        DetailRow(label: "debug.method".localized, value: log.method)
                        if let status = log.statusCode {
                            DetailRow(label: "debug.status_code".localized, value: "\(status)")
                        }
                        if let duration = log.duration {
                            DetailRow(label: "debug.duration".localized, value: String(format: "debug.duration_seconds".localized, duration))
                        }
                        DetailRow(label: "debug.timestamp".localized, value: formatFullTimestamp(log.timestamp))
                    }

                    // Request Body
                    if let requestBody = log.requestBody {
                        DetailSection(title: "debug.request_body".localized) {
                            Text(requestBody)
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                                .background(Color(nsColor: .textBackgroundColor))
                                .cornerRadius(6)
                        }
                    }

                    // Response Preview
                    if let response = log.responsePreview {
                        DetailSection(title: "debug.response_preview".localized) {
                            VStack(alignment: .leading, spacing: 8) {
                                if let size = log.fullResponseSize {
                                    Text(String(format: "debug.full_size".localized, ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)))
                                        .font(DesignTokens.Typography.caption)
                                        .foregroundColor(SettingsColors.secondary)
                                }

                                Text(response)
                                    .font(.system(size: 11, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(8)
                                    .background(Color(nsColor: .textBackgroundColor))
                                    .cornerRadius(6)
                            }
                        }
                    }

                    // Error
                    if let error = log.errorMessage {
                        DetailSection(title: "debug.error".localized) {
                            SettingsStatusBanner(tone: .error, icon: "xmark.circle.fill") {
                                Text(error)
                                    .font(.system(size: 11, design: .monospaced))
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
                .padding()
            }
        }
        .frame(width: 600, height: 500)
    }

    private func formatFullTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }
}

struct DetailSection<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))

            content
        }
    }
}

struct DetailRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top) {
            Text(label + ":")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(SettingsColors.secondary)
                .frame(width: 120, alignment: .leading)

            Text(value)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Preview

#Preview {
    DebugNetworkLogView()
        .frame(width: 520, height: 600)
}
