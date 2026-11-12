import AgentBarCore
import SwiftUI

/// 下拉面板：顶部图标页签，中间是选中 agent 的信息，底部是刷新状态和操作。
struct PanelView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.results.isEmpty {
                Text(emptyMessage)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
            } else {
                tabs
                Divider()
                if let selected = model.selected {
                    AgentDetailView(
                        result: selected, warnings: model.rules.warnings(for: selected.outcome, now: Date()),
                        rules: model.rules)
                        .padding(12)
                }
            }
            Divider()
            footer
        }
        .frame(width: 320)
        .onAppear { Task { await model.refresh() } }
    }

    private var emptyMessage: String {
        if model.isRefreshing { return "正在读取…" }
        if !model.installedProviders.isEmpty { return "所有 agent 都已隐藏，可以在设置中重新显示" }
        return "没有发现已安装的 agent"
    }

    private var tabs: some View {
        HStack(spacing: 4) {
            ForEach(model.results, id: \.provider.id) { result in
                TabButton(
                    result: result,
                    isSelected: result.provider.id == model.selectedID,
                    hasWarning: model.warning(for: result) != nil
                ) {
                    model.select(result.provider.id)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                if model.isRefreshing {
                    ProgressView().controlSize(.small)
                    Text("刷新中…")
                } else if let lastRefreshedAt = model.lastRefreshedAt {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text("上次刷新：\(RelativeTime.describe(lastRefreshedAt, now: context.date))")
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(height: 16)
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)

            MenuRow(title: "刷新", shortcut: "⌘R") { Task { await model.refresh() } }
                .keyboardShortcut("r")
            MenuRow(title: "设置…", shortcut: "⌘,") { SettingsWindow.show(model: model) }
                .keyboardShortcut(",")
            MenuRow(title: "退出", shortcut: "⌘Q") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
        .padding(.bottom, 6)
    }
}

/// 一个图标页签；有警示时右上角带小红点。
private struct TabButton: View {
    let result: ProviderResult
    let isSelected: Bool
    let hasWarning: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            AgentIconView(iconName: result.provider.iconName, displayName: result.provider.displayName, size: 18)
                .frame(width: 32, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isSelected ? Color.primary.opacity(0.1) : .clear))
                .overlay(alignment: .topTrailing) {
                    if hasWarning {
                        Circle().fill(.red).frame(width: 7, height: 7).offset(x: -3, y: 3)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? .primary : .secondary)
        .help(result.provider.displayName)
    }
}

/// 选中 agent 的信息区。
private struct AgentDetailView: View {
    let result: ProviderResult
    let warnings: [Warning]
    let rules: WarningRules

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(result.provider.displayName).font(.headline)
            switch result.outcome {
            case .success(let status):
                statusView(status)
            case .failure:
                warningLines
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func statusView(_ status: SubscriptionStatus) -> some View {
        HStack {
            Text(status.plan.displayName)
            Spacer()
            StateBadge(state: status.state)
        }
        if let account = status.account {
            Text(account).foregroundStyle(.secondary).textSelection(.enabled)
        }
        if let organization = status.organization {
            Text("组织：\(organization)").foregroundStyle(.secondary)
        }
        if let periodEnd = status.periodEnd {
            let now = Date()
            let days = rules.relativeDays(rules.daysUntil(periodEnd, from: now))
            Text("\(status.state == .trial ? "试用到期" : "到期/续费")：\(rules.formatDate(periodEnd, now: now))（\(days)）")
                .foregroundStyle(.secondary)
        }
        UsageSection(usage: status.usage, rules: rules)
        warningLines
        if !status.details.isEmpty {
            DisclosureGroup("详情") {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(status.details.enumerated()), id: \.offset) { _, detail in
                        HStack(alignment: .firstTextBaseline) {
                            Text(detail.label).foregroundStyle(.secondary)
                            Spacer()
                            Text(detail.value).textSelection(.enabled)
                        }
                    }
                }
                .font(.system(.caption, design: .monospaced))
                .padding(.top, 2)
            }
            .font(.callout)
        }
        if let updatedAt = status.sourceUpdatedAt {
            Text("数据来源更新于 \(RelativeTime.describe(updatedAt, now: Date()))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// 所有警示，按严重程度从高到低逐条显示。
    private var warningLines: some View {
        ForEach(Array(warnings.enumerated()), id: \.offset) { _, warning in
            Label(warning.message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// 用量区：每个额度窗口一行（名称、进度条、百分比、重置时间），以及数据来源时间。
/// 拿不到用量时只显示原因。每分钟刷新一次，面板开着时倒计时也会更新。
private struct UsageSection: View {
    let usage: UsageAvailability
    let rules: WarningRules

    var body: some View {
        if let usage = usage.usage, !usage.windows.isEmpty {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                VStack(alignment: .leading, spacing: 4) {
                    Text("用量").font(.callout.weight(.medium))
                    Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
                        ForEach(usage.windows, id: \.id) { window in
                            row(window.effective(at: context.date), now: context.date)
                        }
                    }
                    if let capturedAt = usage.capturedAt {
                        Text("快照于 \(RelativeTime.describe(capturedAt, now: context.date))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 2)
        } else if let reason = usage.unavailableReason {
            Text("用量：\(reason)").foregroundStyle(.secondary)
        }
    }

    private func row(_ window: EffectiveUsageWindow, now: Date) -> some View {
        let percent = window.usedPercent
        return GridRow {
            Text(window.window.name)
            UsageBar(fraction: percent / 100, color: color(for: percent))
                .frame(width: 70, height: 6)
            Text("\(Int(percent.rounded()))%")
                .monospacedDigit()
                .gridColumnAlignment(.trailing)
            Text(resetDescription(window, now: now))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .font(.callout)
    }

    private func resetDescription(_ window: EffectiveUsageWindow, now: Date) -> String {
        if window.isInferredReset { return "已重置（推测）" }
        return window.window.resetsAt.map { rules.resetText($0, now: now) } ?? ""
    }

    private func color(for percent: Double) -> Color {
        if percent >= 100 { return .red }
        if percent >= Double(rules.usageThreshold) { return .orange }
        return .accentColor
    }
}

private struct UsageBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule()
                    .fill(color)
                    .frame(width: proxy.size.width * min(max(fraction, 0), 1))
            }
        }
    }
}

private struct StateBadge: View {
    let state: SubscriptionStatus.State

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    private var label: String {
        switch state {
        case .active: "有效"
        case .trial: "试用中"
        case .expired: "已过期"
        case .signedOut: "未登录"
        case .unknown: "未知"
        }
    }

    private var color: Color {
        switch state {
        case .active: .green
        case .trial: .blue
        case .expired: .red
        case .signedOut, .unknown: .gray
        }
    }
}

/// 菜单风格的一行按钮：左边标题，右边快捷键提示，悬停时高亮。
private struct MenuRow: View {
    let title: String
    let shortcut: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                Text(shortcut).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 4).fill(isHovered ? Color.primary.opacity(0.1) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .onHover { isHovered = $0 }
    }
}

enum RelativeTime {
    /// “刚刚” / “3 分钟前” / “2 小时前” …
    static func describe(_ date: Date, now: Date) -> String {
        if now.timeIntervalSince(date) < 60 { return "刚刚" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
