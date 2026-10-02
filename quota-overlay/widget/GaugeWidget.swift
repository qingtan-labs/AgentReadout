import Foundation
import SwiftUI
import WidgetKit

private let widgetKind = "com.qingtanlabs.gaugeforcodex.quota"
private let snapshotURL = URL(string: "http://127.0.0.1:38429/widget")!
private let cacheKey = "NativeWidgetLastSnapshot"

private struct QuotaWindow: Codable {
    let remainingPercent: Double
    let resetsAt: TimeInterval
    let windowDurationMins: Double
    let kind: String

    var safePercent: Double { min(100, max(0, remainingPercent)) }

    var isFiveHour: Bool { windowDurationMins > 0 && windowDurationMins <= 360 }
    var isSevenDay: Bool { windowDurationMins >= 7 * 24 * 60 - 60 }
}

private struct QuotaSnapshot: Codable {
    let windows: [QuotaWindow]
    let updatedAt: TimeInterval

    static let empty = QuotaSnapshot(windows: [], updatedAt: 0)
    static let preview = QuotaSnapshot(windows: [
        QuotaWindow(remainingPercent: 68, resetsAt: Date().addingTimeInterval(2 * 3600).timeIntervalSince1970,
                    windowDurationMins: 300, kind: "primary"),
        QuotaWindow(remainingPercent: 81, resetsAt: Date().addingTimeInterval(6 * 86400).timeIntervalSince1970,
                    windowDurationMins: 10080, kind: "secondary")
    ], updatedAt: Date().timeIntervalSince1970)

    var mostConstrained: QuotaWindow? {
        windows.min { $0.safePercent < $1.safePercent }
    }

    var orderedWindows: [QuotaWindow] {
        windows.sorted {
            let left = $0.windowDurationMins > 0 ? $0.windowDurationMins : Double.greatestFiniteMagnitude
            let right = $1.windowDurationMins > 0 ? $1.windowDurationMins : Double.greatestFiniteMagnitude
            return left < right
        }
    }
}

private struct QuotaEntry: TimelineEntry {
    let date: Date
    let snapshot: QuotaSnapshot

    var isStale: Bool { snapshot.updatedAt <= 0 || date.timeIntervalSince1970 - snapshot.updatedAt > 300 }
}

private struct QuotaProvider: TimelineProvider {
    func placeholder(in context: Context) -> QuotaEntry {
        QuotaEntry(date: Date(), snapshot: .preview)
    }

    func getSnapshot(in context: Context, completion: @escaping (QuotaEntry) -> Void) {
        completion(QuotaEntry(date: Date(), snapshot: context.isPreview ? .preview : cachedSnapshot()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<QuotaEntry>) -> Void) {
        var request = URLRequest(url: snapshotURL)
        request.timeoutInterval = 2
        URLSession.shared.dataTask(with: request) { data, response, _ in
            let snapshot: QuotaSnapshot
            if let data,
               (response as? HTTPURLResponse)?.statusCode == 200,
               let decoded = try? JSONDecoder().decode(QuotaSnapshot.self, from: data) {
                UserDefaults.standard.set(data, forKey: cacheKey)
                snapshot = decoded
            } else {
                snapshot = cachedSnapshot()
            }
            let now = Date()
            let entry = QuotaEntry(date: now, snapshot: snapshot)
            completion(Timeline(entries: [entry], policy: .after(now.addingTimeInterval(5 * 60))))
        }.resume()
    }

    private func cachedSnapshot() -> QuotaSnapshot {
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
              let snapshot = try? JSONDecoder().decode(QuotaSnapshot.self, from: data) else { return .empty }
        return snapshot
    }
}

private enum Copy {
    static var language: String { Locale.current.languageCode ?? "en" }

    static func localized(zh: String, ja: String, es: String, en: String) -> String {
        switch language {
        case "zh": return zh
        case "ja": return ja
        case "es": return es
        default: return en
        }
    }

    static var title: String { localized(zh: "Codex 额度", ja: "Codex 使用枠", es: "Cuota de Codex", en: "Codex quota") }
    static var noData: String { localized(zh: "打开 Gauge 以同步额度", ja: "Gauge を開いて同期", es: "Abre Gauge para sincronizar", en: "Open Gauge to sync quota") }
    static var stale: String { localized(zh: "上次同步", ja: "最終同期", es: "Última sincronización", en: "Last sync") }
    static var resets: String { localized(zh: "重置", ja: "リセット", es: "Reinicio", en: "Resets") }
    static var description: String {
        localized(zh: "在桌面查看 Codex 剩余额度与重置时间",
                  ja: "Codex の残り使用枠とリセット時刻をデスクトップに表示",
                  es: "Consulta la cuota restante de Codex y la hora de reinicio en el escritorio",
                  en: "See Codex quota and reset times on your desktop")
    }

    static func label(_ window: QuotaWindow) -> String {
        if window.isFiveHour { return localized(zh: "5 小时", ja: "5 時間", es: "5 horas", en: "5 hours") }
        if window.isSevenDay { return localized(zh: "7 天", ja: "7 日", es: "7 días", en: "7 days") }
        if window.windowDurationMins > 0 {
            let hours = Int((window.windowDurationMins / 60).rounded())
            return localized(zh: "\(hours) 小时", ja: "\(hours) 時間", es: "\(hours) horas", en: "\(hours) hours")
        }
        return window.kind == "secondary"
            ? localized(zh: "次级额度", ja: "二次枠", es: "Secundaria", en: "Secondary")
            : localized(zh: "额度", ja: "使用枠", es: "Cuota", en: "Quota")
    }
}

private struct GaugeMark: View {
    var body: some View {
        GeometryReader { geometry in
            let scale = min(geometry.size.width, geometry.size.height) / 24
            ZStack {
                Path { path in
                    path.addArc(center: CGPoint(x: 12, y: 12), radius: 8.5,
                                startAngle: .degrees(45), endAngle: .degrees(315), clockwise: false)
                }
                .stroke(style: StrokeStyle(lineWidth: 3, lineCap: .round))
                Path { path in
                    path.move(to: CGPoint(x: 8.5, y: 8.5))
                    path.addLine(to: CGPoint(x: 12, y: 12))
                    path.addLine(to: CGPoint(x: 8.5, y: 15.5))
                    path.move(to: CGPoint(x: 15, y: 15.5))
                    path.addLine(to: CGPoint(x: 18.5, y: 15.5))
                }
                .stroke(style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
            .scaleEffect(scale, anchor: .topLeading)
        }
    }
}

private struct QuotaProgress: View {
    let percent: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.22))
                Capsule()
                    .fill(.primary)
                    .frame(width: max(5, geometry.size.width * min(100, max(0, percent)) / 100))
                    .widgetAccentable()
            }
        }
        .frame(height: 5)
        .accessibilityLabel("\(Int(percent.rounded()))%")
    }
}

private struct QuotaBlock: View {
    let window: QuotaWindow
    let compact: Bool

    private var resetDate: Date? {
        window.resetsAt > 0 ? Date(timeIntervalSince1970: window.resetsAt) : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 5 : 7) {
            Text(Copy.label(window))
                .font(.system(size: compact ? 11 : 12, weight: .medium))
                .lineLimit(1)
                .foregroundStyle(.primary.opacity(0.82))
            Text("\(Int(window.safePercent.rounded()))%")
                .font(.system(size: compact ? 39 : 37, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.75)
                .lineLimit(1)
            QuotaProgress(percent: window.safePercent)
            if let resetDate {
                Text(resetDate, style: .relative)
                    .font(.system(size: compact ? 10 : 11, weight: .medium))
                    .lineLimit(1)
                Text("\(Copy.resets) \(resetDate.formatted(date: .numeric, time: .shortened))")
                    .font(.system(size: compact ? 9 : 10, weight: .regular))
                    .lineLimit(1)
                    .foregroundStyle(.primary.opacity(0.82))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct QuotaWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: QuotaEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                GaugeMark()
                    .frame(width: 21, height: 21)
                    .accessibilityHidden(true)
                Text(Copy.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }

            Spacer(minLength: 10)
            if entry.snapshot.windows.isEmpty {
                Text("--%")
                    .font(.system(size: 39, weight: .semibold, design: .rounded))
                Text(Copy.noData)
                    .font(.system(size: 10))
                    .lineLimit(2)
            } else if family == .systemMedium && entry.snapshot.orderedWindows.count > 1 {
                HStack(alignment: .top, spacing: 15) {
                    ForEach(Array(entry.snapshot.orderedWindows.prefix(2).enumerated()), id: \.offset) { item in
                        QuotaBlock(window: item.element, compact: false)
                    }
                }
            } else if let window = entry.snapshot.mostConstrained {
                QuotaBlock(window: window, compact: family == .systemSmall)
            }
            if entry.isStale && entry.snapshot.updatedAt > 0 {
                Text("\(Copy.stale) \(Date(timeIntervalSince1970: entry.snapshot.updatedAt).formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 8))
                    .foregroundStyle(.primary.opacity(0.7))
                    .padding(.top, 4)
                    .lineLimit(1)
            }
        }
        .padding(family == .systemSmall ? 15 : 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(for: .widget) {
            Color(nsColor: .windowBackgroundColor)
        }
    }
}

@main
struct CodexQuotaWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: widgetKind, provider: QuotaProvider()) { entry in
            QuotaWidgetView(entry: entry)
        }
        .configurationDisplayName(Copy.title)
        .description(Copy.description)
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
