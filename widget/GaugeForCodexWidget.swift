import AppKit
import SwiftUI
import WidgetKit

private let appGroupIdentifier = "group.com.qingtanlabs.gaugeforcodex"
private let widgetKind = "com.qingtanlabs.gaugeforcodex.usage"

private struct QuotaWindow: Identifiable {
    let id: String
    let remainingPercent: Double
    let resetAt: Date?
    let durationMinutes: Double

    var fraction: Double { min(1, max(0, remainingPercent / 100)) }

    var durationLabel: String {
        if durationMinutes >= 1_440 {
            let days = max(1, Int((durationMinutes / 1_440).rounded()))
            return String(format: NSLocalizedString("widget.days", comment: ""), days)
        }
        if durationMinutes >= 60 {
            let hours = max(1, Int((durationMinutes / 60).rounded()))
            return String(format: NSLocalizedString("widget.hours", comment: ""), hours)
        }
        return NSLocalizedString("widget.window", comment: "")
    }
}

private struct GaugeEntry: TimelineEntry {
    let date: Date
    let windows: [QuotaWindow]
    let lastUpdated: Date?

    var selected: QuotaWindow? {
        windows.min { $0.remainingPercent < $1.remainingPercent }
    }
}

private struct GaugeProvider: TimelineProvider {
    func placeholder(in context: Context) -> GaugeEntry {
        sampleEntry
    }

    func getSnapshot(in context: Context, completion: @escaping (GaugeEntry) -> Void) {
        completion(context.isPreview ? sampleEntry : loadEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<GaugeEntry>) -> Void) {
        let entry = loadEntry()
        let nextRefresh = Date().addingTimeInterval(15 * 60)
        completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
    }

    private var sampleEntry: GaugeEntry {
        GaugeEntry(
            date: Date(),
            windows: [
                QuotaWindow(id: "primary", remainingPercent: 89, resetAt: Date().addingTimeInterval(2 * 3_600), durationMinutes: 300),
                QuotaWindow(id: "secondary", remainingPercent: 56, resetAt: Date().addingTimeInterval(4 * 86_400 + 7_200), durationMinutes: 10_080),
            ],
            lastUpdated: Date()
        )
    }

    private func loadEntry() -> GaugeEntry {
        let defaults = UserDefaults(suiteName: appGroupIdentifier)
        let rawWindows = defaults?.array(forKey: "QuotaWindows") as? [[String: Any]] ?? []
        let windows = rawWindows.enumerated().compactMap { index, raw -> QuotaWindow? in
            guard let remaining = number(raw["remainingPercent"]) else { return nil }
            let resetSeconds = number(raw["resetsAt"]) ?? 0
            let duration = number(raw["windowDurationMins"]) ?? 0
            let kind = raw["kind"] as? String ?? "window-\(index)"
            return QuotaWindow(
                id: "\(kind)-\(index)",
                remainingPercent: min(100, max(0, remaining)),
                resetAt: resetSeconds > 0 ? Date(timeIntervalSince1970: resetSeconds) : nil,
                durationMinutes: max(0, duration)
            )
        }
        let lastSync = defaults?.double(forKey: "LastSuccessfulSync") ?? 0
        return GaugeEntry(
            date: Date(),
            windows: windows,
            lastUpdated: lastSync > 0 ? Date(timeIntervalSince1970: lastSync) : nil
        )
    }

    private func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }
}

private struct WidgetBackground: View {
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            Color(nsColor: .windowBackgroundColor)
                .opacity(renderingMode == .fullColor ? 0.84 : 0.18)
            LinearGradient(
                colors: [Color.cyan.opacity(0.13), Color.green.opacity(0.08), Color.clear],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }
}

private struct ProgressBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.secondary.opacity(0.16))
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [.cyan, Color(red: 0.36, green: 0.88, blue: 0.62)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(5, proxy.size.width * fraction))
                    .widgetAccentable()
            }
        }
        .frame(height: 7)
    }
}

private struct SmallGaugeView: View {
    let entry: GaugeEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "terminal.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.cyan)
                    .widgetAccentable()
                Text("widget.title")
                    .font(.caption.weight(.semibold))
                Spacer(minLength: 0)
            }

            if let selected = entry.selected {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(Int(selected.remainingPercent.rounded()))")
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text("%")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Text(selected.durationLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ProgressBar(fraction: selected.fraction)
                resetLabel(for: selected)
            } else {
                Spacer(minLength: 0)
                Text("--%")
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                Text("widget.openApp")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    private func resetLabel(for window: QuotaWindow) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.clockwise")
            if let resetAt = window.resetAt, resetAt > Date() {
                Text(resetAt, style: .relative)
            } else {
                Text("widget.resetUnknown")
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}

private struct WindowCard: View {
    let window: QuotaWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(window.durationLabel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("\(Int(window.remainingPercent.rounded()))%")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .monospacedDigit()
            ProgressBar(fraction: window.fraction)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct MediumGaugeView: View {
    let entry: GaugeEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Image(systemName: "terminal.fill")
                    .foregroundStyle(.cyan)
                    .widgetAccentable()
                Text("widget.title")
                    .font(.headline)
                Spacer()
                if let updated = entry.lastUpdated {
                    Text(updated, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if entry.windows.isEmpty {
                Spacer()
                Text("widget.openApp")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                HStack(spacing: 10) {
                    ForEach(Array(entry.windows.prefix(2))) { window in
                        WindowCard(window: window)
                    }
                }
                if let selected = entry.selected {
                    HStack(spacing: 5) {
                        Image(systemName: "clock")
                        Text("widget.nextReset")
                        if let resetAt = selected.resetAt, resetAt > Date() {
                            Text(resetAt, style: .relative)
                                .fontWeight(.semibold)
                        } else {
                            Text("widget.resetUnknown")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct GaugeWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: GaugeEntry

    var body: some View {
        Group {
            if family == .systemMedium {
                MediumGaugeView(entry: entry)
            } else {
                SmallGaugeView(entry: entry)
            }
        }
        .containerBackground(for: .widget) {
            WidgetBackground()
        }
        .widgetURL(URL(string: "gaugeforcodex://refresh"))
    }
}

@main
struct GaugeForCodexWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: widgetKind, provider: GaugeProvider()) { entry in
            GaugeWidgetView(entry: entry)
        }
        .configurationDisplayName("widget.name")
        .description("widget.description")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
