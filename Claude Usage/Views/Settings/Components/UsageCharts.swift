//
//  UsageCharts.swift
//  Claude Usage
//
//  Created by Claude Code on 2025-01-26.
//

import SwiftUI
import Charts
import UsageCore

/// Provider-neutral chart for an arbitrary normalized usage window.
struct NormalizedUsageChart: View {
    let title: String
    let snapshots: [NormalizedUsageSnapshot]
    @Binding var timeScale: ChartTimeScale
    @State private var timeOffset: Double = 0

    private var visibleRange: ClosedRange<Date> {
        let end = Date().addingTimeInterval(timeOffset * 3600)
        return end.addingTimeInterval(
            -timeScale.rawValue * 3600
        )...end
    }

    private var visibleSnapshots: [NormalizedUsageSnapshot] {
        snapshots.filter {
            visibleRange.contains($0.timestamp)
        }
    }

    private var canGoBack: Bool {
        guard let oldest = snapshots.map(\.timestamp).min() else {
            return false
        }
        return oldest < visibleRange.lowerBound
    }

    private var canGoForward: Bool {
        timeOffset < 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(SettingsColors.secondary)
                Spacer()
                Button {
                    timeOffset -= timeScale.rawValue / 2
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.plain)
                .disabled(!canGoBack)
                Button {
                    timeOffset = min(
                        0,
                        timeOffset + timeScale.rawValue / 2
                    )
                } label: {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.plain)
                .disabled(!canGoForward)
            }

            Chart(visibleSnapshots) { snapshot in
                if let percentage = snapshot.usedPercentage
                    ?? snapshot.quantity?
                        .calculatedUsedPercentage {
                    LineMark(
                        x: .value("Time", snapshot.timestamp),
                        y: .value(
                            "Usage",
                            min(max(percentage, 0), 100)
                        )
                    )
                    .interpolationMethod(.stepEnd)
                    .foregroundStyle(Color.accentColor)

                    AreaMark(
                        x: .value("Time", snapshot.timestamp),
                        y: .value(
                            "Usage",
                            min(max(percentage, 0), 100)
                        )
                    )
                    .interpolationMethod(.stepEnd)
                    .foregroundStyle(
                        Color.accentColor.opacity(0.12)
                    )
                }
            }
            .chartXScale(domain: visibleRange)
            .chartYScale(domain: 0...100)
            .chartYAxis {
                AxisMarks(
                    position: .leading,
                    values: [0, 50, 100]
                ) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let intValue = value.as(Int.self) {
                            Text("\(intValue)%")
                                .font(.system(size: 9))
                        }
                    }
                }
            }
            .frame(height: 140)
        }
        .padding(12)
        .background(SettingsColors.cardBackground)
        .cornerRadius(8)
        .onChange(of: timeScale) {
            timeOffset = 0
        }
    }
}

/// Data point for timeline chart
struct TimeSlot: Identifiable, Equatable {
    let id = UUID()
    let time: Date
    let percentage: Double?

    var timeLabel: String {
        let formatter = DateFormatter()
        formatter.dateFormat = SharedDataStore.shared.uses24HourTime() ? "HH:mm" : "h:mma"
        return formatter.string(from: time)
    }

    var fullTimeLabel: String {
        let formatter = DateFormatter()
        let timeFmt = SharedDataStore.shared.uses24HourTime() ? "HH:mm" : "h:mma"
        formatter.dateFormat = "MM/dd \(timeFmt)"
        return formatter.string(from: time)
    }

    static func == (lhs: TimeSlot, rhs: TimeSlot) -> Bool {
        lhs.id == rhs.id
    }
}

/// Chart style enum
enum ChartStyle: String, CaseIterable {
    case line = "Line"
    case bar = "Bars"
}

/// Chart displaying session usage history (plots all data in selected range)
struct SessionUsageChart: View {
    let snapshots: [UsageSnapshot]
    let chartStyle: ChartStyle

    /// Selected time for showing details
    @State private var selectedSnapshot: UsageSnapshot?

    init(snapshots: [UsageSnapshot], chartStyle: ChartStyle = .line) {
        self.snapshots = snapshots
        self.chartStyle = chartStyle
    }

    /// Get info for selected snapshot
    private var selectedSlotInfo: (time: String, percentage: String)? {
        guard let snapshot = selectedSnapshot else { return nil }

        let formatter = DateFormatter()
        formatter.dateFormat = "MM/dd HH:mm"
        let timeStr = formatter.string(from: snapshot.timestamp)

        return (timeStr, String(format: "%.1f%%", snapshot.sessionPercentage ?? 0))
    }

    /// Clamp percentage to 0-100 range
    private func clampedPercentage(_ value: Double?) -> Double {
        guard let v = value else { return 0 }
        return min(max(v, 0), 100)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Title with selected info
            HStack {
                Text("history.chart.session_title".localized)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(SettingsColors.secondary)

                // Show selected snapshot info (only when hovering over a data point)
                if let info = selectedSlotInfo {
                    Spacer()
                    HStack(spacing: 4) {
                        Text(info.time)
                            .font(.system(size: 11))
                            .foregroundColor(SettingsColors.secondary)
                        Text(info.percentage)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.primary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(4)
                }
            }

            Chart(snapshots) { snapshot in
                if chartStyle == .bar {
                    BarMark(
                        x: .value("Time", snapshot.timestamp, unit: .minute),
                        y: .value("Usage", clampedPercentage(snapshot.sessionPercentage)),
                        width: .fixed(8)
                    )
                    .foregroundStyle(snapshot.sessionPercentage.map { barColor(for: $0) } ?? SettingsColors.neutral.opacity(0.2))
                    .cornerRadius(2)
                } else {
                    // Only show points, no connecting lines (to avoid misleading gaps)
                    PointMark(
                        x: .value("Time", snapshot.timestamp, unit: .minute),
                        y: .value("Usage", clampedPercentage(snapshot.sessionPercentage))
                    )
                    .foregroundStyle(snapshot.sessionPercentage.map { barColor(for: $0) } ?? SettingsColors.neutral.opacity(0.2))
                    .symbolSize(60)
                }
            }
            .chartYScale(domain: 0...100)
            .chartPlotStyle { plotArea in
                plotArea.clipped()
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: [0, 50, 100]) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [4]))
                        .foregroundStyle(Color.secondary.opacity(0.3))
                    AxisValueLabel {
                        if let intValue = value.as(Int.self) {
                            Text("\(intValue)%")
                                .font(.system(size: 10))
                                .foregroundColor(SettingsColors.secondary)
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic) { value in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day().hour(.defaultDigits(amPM: .omitted)))
                        .font(.system(size: 8))
                }
            }
            .frame(height: 140)
            .padding(.leading, 4)
        }
        .padding(16)
        .background(SettingsColors.cardBackground)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(SettingsColors.border, lineWidth: 1)
        )
    }

    private func barColor(for percentage: Double) -> Color {
        switch percentage {
        case 0..<50:
            return SettingsColors.success
        case 50..<80:
            return SettingsColors.warning
        default:
            return SettingsColors.error
        }
    }
}

/// Chart displaying weekly usage history (plots all data in selected range)
struct WeeklyUsageChart: View {
    let snapshots: [UsageSnapshot]
    let chartStyle: ChartStyle

    /// Selected snapshot for showing details
    @State private var selectedSnapshot: UsageSnapshot?

    init(snapshots: [UsageSnapshot], chartStyle: ChartStyle = .line) {
        self.snapshots = snapshots
        self.chartStyle = chartStyle
    }

    /// Get info for selected snapshot
    private var selectedSlotInfo: (time: String, percentage: String)? {
        guard let snapshot = selectedSnapshot else { return nil }

        let formatter = DateFormatter()
        formatter.dateFormat = "MM/dd HH:mm"
        let timeStr = formatter.string(from: snapshot.timestamp)

        return (timeStr, String(format: "%.1f%%", snapshot.weeklyPercentage ?? 0))
    }

    /// Clamp percentage to 0-100 range
    private func clampedPercentage(_ value: Double?) -> Double {
        guard let v = value else { return 0 }
        return min(max(v, 0), 100)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Title with selected info
            HStack {
                Text("history.chart.weekly_title".localized)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(SettingsColors.secondary)

                // Show selected snapshot info (only when hovering over a data point)
                if let info = selectedSlotInfo {
                    Spacer()
                    HStack(spacing: 4) {
                        Text(info.time)
                            .font(.system(size: 11))
                            .foregroundColor(SettingsColors.secondary)
                        Text(info.percentage)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.primary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(4)
                }
            }

            // Chart container
            Chart(snapshots) { snapshot in
                if chartStyle == .bar {
                    BarMark(
                        x: .value("Time", snapshot.timestamp, unit: .hour),
                        y: .value("Usage", clampedPercentage(snapshot.weeklyPercentage)),
                        width: .fixed(20)
                    )
                    .foregroundStyle(snapshot.weeklyPercentage.map { barColor(for: $0) } ?? SettingsColors.neutral.opacity(0.2))
                    .cornerRadius(3)
                } else {
                    // Only show points, no connecting lines (to avoid misleading gaps)
                    PointMark(
                        x: .value("Time", snapshot.timestamp, unit: .hour),
                        y: .value("Usage", clampedPercentage(snapshot.weeklyPercentage))
                    )
                    .foregroundStyle(snapshot.weeklyPercentage.map { barColor(for: $0) } ?? SettingsColors.neutral.opacity(0.2))
                    .symbolSize(80)
                }
            }
            .chartYScale(domain: 0...100)
            .chartPlotStyle { plotArea in
                plotArea.clipped()
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: [0, 50, 100]) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [4]))
                        .foregroundStyle(Color.secondary.opacity(0.3))
                    AxisValueLabel {
                        if let intValue = value.as(Int.self) {
                            Text("\(intValue)%")
                                .font(.system(size: 10))
                                .foregroundColor(SettingsColors.secondary)
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic) { value in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day().hour(.defaultDigits(amPM: .omitted)))
                        .font(.system(size: 8))
                }
            }
            .frame(height: 140)
            .padding(.leading, 4)
        }
        .padding(16)
        .background(SettingsColors.cardBackground)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(SettingsColors.border, lineWidth: 1)
        )
    }

    private func barColor(for percentage: Double) -> Color {
        switch percentage {
        case 0..<50:
            return SettingsColors.success
        case 50..<80:
            return SettingsColors.warning
        default:
            return SettingsColors.error
        }
    }
}

/// Chart displaying billing cycle history
struct BillingCycleChart: View {
    let snapshots: [UsageSnapshot]
    let chartStyle: ChartStyle
    let maxItems: Int

    init(snapshots: [UsageSnapshot], chartStyle: ChartStyle = .line, maxItems: Int = 12) {
        self.snapshots = snapshots
        self.chartStyle = chartStyle
        self.maxItems = maxItems
    }

    private var chartData: [UsageSnapshot] {
        // Take the most recent snapshots and reverse for chronological order
        Array(snapshots.prefix(maxItems).reversed())
    }

    private var maxSpend: Double {
        let maxCents = chartData.compactMap { $0.apiSpendCents }.max() ?? 0
        return Swift.max(Double(maxCents) / 100.0, 10.0)  // Minimum $10 for scale
    }

    var body: some View {
        if chartData.isEmpty {
            EmptyHistoryView(type: .billing)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("history.chart.billing_title".localized)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(SettingsColors.secondary)

                Chart(chartData) { snapshot in
                    let spendAmount = Double(snapshot.apiSpendCents ?? 0) / 100.0

                    if chartStyle == .bar {
                        BarMark(
                            x: .value("Date", snapshot.timestamp, unit: .hour),
                            y: .value("Spend", spendAmount)
                        )
                        .foregroundStyle(Color.accentColor)
                    } else {
                        LineMark(
                            x: .value("Date", snapshot.timestamp, unit: .hour),
                            y: .value("Spend", spendAmount)
                        )
                        .foregroundStyle(Color.accentColor)
                        .interpolationMethod(.catmullRom)

                        AreaMark(
                            x: .value("Date", snapshot.timestamp, unit: .hour),
                            y: .value("Spend", spendAmount)
                        )
                        .foregroundStyle(
                            LinearGradient(
                                colors: [Color.accentColor.opacity(0.3), Color.accentColor.opacity(0.05)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .interpolationMethod(.catmullRom)

                        PointMark(
                            x: .value("Date", snapshot.timestamp, unit: .hour),
                            y: .value("Spend", spendAmount)
                        )
                        .foregroundStyle(Color.accentColor)
                        .symbolSize(30)
                    }
                }
                .chartYScale(domain: 0...maxSpend * 1.1)
                .chartYAxis {
                    AxisMarks { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [4]))
                            .foregroundStyle(Color.secondary.opacity(0.3))
                        AxisValueLabel {
                            if let doubleValue = value.as(Double.self) {
                                Text("$\(Int(doubleValue))")
                                    .font(.system(size: 10))
                                    .foregroundColor(SettingsColors.secondary)
                            }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic) { value in
                        AxisValueLabel(format: .dateTime.month(.twoDigits).day().hour(.defaultDigits(amPM: .omitted)))
                            .font(.system(size: 9))
                    }
                }
                .chartPlotStyle { plotArea in
                    plotArea
                        .background(Color.clear)
                }
                .frame(height: 160)
            }
            .padding(16)
            .background(SettingsColors.cardBackground)
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(SettingsColors.border, lineWidth: 1)
            )
        }
    }
}

/// Empty state view for history
struct EmptyHistoryView: View {
    enum HistoryType {
        case session
        case weekly
        case billing

        var icon: String {
            switch self {
            case .session:
                return "clock.arrow.circlepath"
            case .weekly:
                return "chart.bar"
            case .billing:
                return "chart.line.uptrend.xyaxis"
            }
        }

        var titleKey: String {
            switch self {
            case .session:
                return "history.empty.session_title"
            case .weekly:
                return "history.empty.weekly_title"
            case .billing:
                return "history.empty.billing_title"
            }
        }

        var descriptionKey: String {
            switch self {
            case .session:
                return "history.empty.session_description"
            case .weekly:
                return "history.empty.weekly_description"
            case .billing:
                return "history.empty.billing_description"
            }
        }
    }

    let type: HistoryType

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: type.icon)
                .font(.system(size: 32))
                .foregroundColor(.secondary.opacity(0.5))

            VStack(spacing: 4) {
                Text(type.titleKey.localized)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.primary)

                Text(type.descriptionKey.localized)
                    .font(.system(size: 11))
                    .foregroundColor(SettingsColors.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 160)
        .padding(16)
        .background(SettingsColors.cardBackground)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(SettingsColors.border, lineWidth: 1)
        )
    }
}

/// Row displaying a single snapshot in the history list
struct SnapshotRow: View {
    let snapshot: UsageSnapshot

    var body: some View {
        HStack(spacing: 12) {
            // Date column
            VStack(alignment: .leading, spacing: 2) {
                Text(snapshot.formattedDate)
                    .font(.system(size: 12))
                    .foregroundColor(.primary)

                Text(snapshot.resetType.localizedName)
                    .font(.system(size: 11))
                    .foregroundColor(SettingsColors.secondary)
            }

            Spacer()

            // Usage data column
            switch snapshot.resetType {
            case .sessionReset:
                sessionUsageView
            case .weeklyReset:
                weeklyUsageView
            case .billingCycle:
                billingUsageView
            }
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var sessionUsageView: some View {
        if let percentage = snapshot.sessionPercentage {
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(Int(percentage))%")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(usageColor(for: percentage))

                Text("history.label.session".localized)
                    .font(.system(size: 10))
                    .foregroundColor(SettingsColors.secondary)
            }
        }
    }

    @ViewBuilder
    private var weeklyUsageView: some View {
        HStack(spacing: 12) {
            if let percentage = snapshot.weeklyPercentage {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(Int(percentage))%")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(usageColor(for: percentage))

                    Text("history.label.total".localized)
                        .font(.system(size: 10))
                        .foregroundColor(SettingsColors.secondary)
                }
            }

            if let opusPercentage = snapshot.opusWeeklyPercentage, opusPercentage > 0 {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(Int(opusPercentage))%")
                        .font(.system(size: 12))
                        .foregroundColor(SettingsColors.secondary)

                    Text("Opus")
                        .font(.system(size: 10))
                        .foregroundColor(SettingsColors.secondary)
                }
            }

            if let sonnetPercentage = snapshot.sonnetWeeklyPercentage, sonnetPercentage > 0 {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(Int(sonnetPercentage))%")
                        .font(.system(size: 12))
                        .foregroundColor(SettingsColors.secondary)

                    Text("Sonnet")
                        .font(.system(size: 10))
                        .foregroundColor(SettingsColors.secondary)
                }
            }

            if let fablePercentage = snapshot.fableWeeklyPercentage, fablePercentage > 0 {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(Int(fablePercentage))%")
                        .font(.system(size: 12))
                        .foregroundColor(SettingsColors.secondary)

                    Text("Fable")
                        .font(.system(size: 10))
                        .foregroundColor(SettingsColors.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var billingUsageView: some View {
        if let formattedSpend = snapshot.formattedApiSpend {
            VStack(alignment: .trailing, spacing: 2) {
                Text(formattedSpend)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.primary)

                Text("history.label.spent".localized)
                    .font(.system(size: 10))
                    .foregroundColor(SettingsColors.secondary)
            }
        }
    }

    private func usageColor(for percentage: Double) -> Color {
        switch percentage {
        case 0..<50:
            return SettingsColors.success
        case 50..<80:
            return SettingsColors.warning
        default:
            return SettingsColors.error
        }
    }
}

#Preview("Weekly Chart") {
    WeeklyUsageChart(snapshots: [
        UsageSnapshot(
            resetType: .weeklyReset,
            weeklyTokensUsed: 500000,
            weeklyPercentage: 50,
            opusWeeklyTokensUsed: 300000,
            opusWeeklyPercentage: 30,
            sonnetWeeklyTokensUsed: 200000,
            sonnetWeeklyPercentage: 20,
            fableWeeklyTokensUsed: 50000,
            fableWeeklyPercentage: 5,
            triggeringResetTime: Date().addingTimeInterval(-7 * 24 * 60 * 60)
        ),
        UsageSnapshot(
            resetType: .weeklyReset,
            weeklyTokensUsed: 750000,
            weeklyPercentage: 75,
            triggeringResetTime: Date().addingTimeInterval(-14 * 24 * 60 * 60)
        ),
        UsageSnapshot(
            resetType: .weeklyReset,
            weeklyTokensUsed: 900000,
            weeklyPercentage: 90,
            triggeringResetTime: Date().addingTimeInterval(-21 * 24 * 60 * 60)
        )
    ])
    .padding()
    .frame(width: 400)
}

#Preview("Empty Weekly") {
    EmptyHistoryView(type: .weekly)
        .padding()
        .frame(width: 400)
}

#Preview("Billing Chart") {
    BillingCycleChart(snapshots: [
        UsageSnapshot(
            resetType: .billingCycle,
            apiSpendCents: 2500,
            apiPrepaidCreditsCents: 5000,
            apiCurrency: "USD",
            triggeringResetTime: Date().addingTimeInterval(-30 * 24 * 60 * 60)
        ),
        UsageSnapshot(
            resetType: .billingCycle,
            apiSpendCents: 4200,
            apiPrepaidCreditsCents: 5000,
            apiCurrency: "USD",
            triggeringResetTime: Date().addingTimeInterval(-60 * 24 * 60 * 60)
        )
    ])
    .padding()
    .frame(width: 400)
}
