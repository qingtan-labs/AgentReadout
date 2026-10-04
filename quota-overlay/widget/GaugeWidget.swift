import Foundation
import SwiftUI
import WidgetKit

private let quotaWidgetKind = "com.qingtanlabs.gaugeforcodex.quota"
private let dailyWidgetKind = "com.qingtanlabs.gaugeforcodex.daily-token"
enum WidgetRoute {
    static let dailyTokens = URL(string: "gaugeforcodex://insights/daily-token")!
}
private let snapshotURL = URL(string: "http://127.0.0.1:38429/widget")!
private let cacheKey = "NativeWidgetLastSnapshot"

struct QuotaWindow: Codable {
    let remainingPercent: Double
    let resetsAt: TimeInterval
    let windowDurationMins: Double
    let kind: String
    var manual: Bool? = nil

    var safePercent: Double { QuotaRingMetrics.fraction(remainingPercent) * 100 }

    var isFiveHour: Bool { abs(windowDurationMins - 300) < 0.5 }
    var isSevenDay: Bool { abs(windowDurationMins - 10080) < 0.5 }
}

struct ProviderQuota: Codable {
    let windows: [QuotaWindow]
    let updatedAt: TimeInterval
    let stale: Bool?
    var planName: String? = nil

    var displayPlan: String? {
        if planName == "Pro Lite" { return "Pro 5×" }
        if planName == "Pro Max" { return "Pro" }
        guard let planName, ["Free", "Go", "Plus", "Pro", "Pro 5×", "Pro 20×", "Team", "Business",
                            "Enterprise", "Edu", "Max", "Max 5×", "Max 20×"].contains(planName) else { return nil }
        return planName
    }

    static let empty = ProviderQuota(windows: [], updatedAt: 0, stale: nil)

    var mostConstrained: QuotaWindow? {
        windows.min {
            if $0.safePercent != $1.safePercent { return $0.safePercent < $1.safePercent }
            if ($0.resetsAt > 0) != ($1.resetsAt > 0) { return $0.resetsAt > 0 }
            return $0.windowDurationMins < $1.windowDurationMins
        }
    }

    var orderedWindows: [QuotaWindow] {
        windows.sorted {
            let left = $0.windowDurationMins > 0 ? $0.windowDurationMins : Double.greatestFiniteMagnitude
            let right = $1.windowDurationMins > 0 ? $1.windowDurationMins : Double.greatestFiniteMagnitude
            return left < right
        }
    }
}

struct DailyTokenDay: Codable {
    let date: String
    let value: Double
}

struct DailyUsageSnapshot: Codable {
    let days: [DailyTokenDay]
    let summary: [String: Double]
    let latest: String
    let updatedAt: TimeInterval
    let available: Bool
    var stale: Bool? = nil

    private static var localCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }

    static var preview: DailyUsageSnapshot {
        let calendar = localCalendar
        let today = calendar.startOfDay(for: Date())
        let values: [Double] = [960_000, 1_240_000, 1_100_000, 1_650_000, 1_310_000, 1_900_000, 720_000]
        let days = values.enumerated().compactMap { index, value -> DailyTokenDay? in
            guard let date = calendar.date(byAdding: .day, value: index - 6, to: today) else { return nil }
            return DailyTokenDay(date: Self.key(for: date), value: value)
        }
        return DailyUsageSnapshot(days: days, summary: ["lifetimeTokens": 5_390_000_000,
            "peakDailyTokens": 390_000_000, "longestRunningTurnSec": 55_260,
            "currentStreakDays": 4, "longestStreakDays": 16],
            latest: days.last?.date ?? "", updatedAt: Date().timeIntervalSince1970, available: true)
    }

    static func key(for date: Date) -> String {
        let components = localCalendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    func recentDays(reference: Date) -> [(date: String, value: Double?)] {
        let calendar = Self.localCalendar
        let today = calendar.startOfDay(for: reference)
        let values = Dictionary(days.map { ($0.date, $0.value) }, uniquingKeysWith: { _, newest in newest })
        return (-6...0).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: today) else { return nil }
            let key = Self.key(for: date)
            return (date: key, value: values[key])
        }
    }

    func todayValue(reference: Date) -> Double? {
        days.first { $0.date == Self.key(for: reference) }?.value
    }

    func isStale(reference: Date) -> Bool {
        stale == true || updatedAt <= 0 || reference.timeIntervalSince1970 - updatedAt > 60 * 60
    }
}

struct QuotaSnapshot: Codable {
    // The first three fields also support extensions installed before dual-provider mode.
    let windows: [QuotaWindow]
    let updatedAt: TimeInterval
    let provider: String?
    let providers: [String: ProviderQuota]?
    let selectedProvider: String?
    let displayMode: String?
    let claudeEnabled: Bool?
    var language: String? = nil
    var localeIdentifier: String? = nil
    var quotaStyle: String? = nil
    var appearanceMode: String? = nil
    var dailyUsage: DailyUsageSnapshot? = nil
    var usesBars: Bool { quotaStyle != "ring" }

    func resolvedColorScheme(system: ColorScheme, tinted: Bool) -> ColorScheme {
        if tinted { return system }
        if appearanceMode == "light" { return .light }
        if appearanceMode == "dark" { return .dark }
        return system
    }

    static let empty = QuotaSnapshot(windows: [], updatedAt: 0, provider: nil,
                                      providers: nil, selectedProvider: nil,
                                      displayMode: nil, claudeEnabled: nil)
    // A long-lived extension must not age its gallery fixtures into stale data.
    static var preview: QuotaSnapshot {
        let now = Date()
        let codex = ProviderQuota(windows: [
            QuotaWindow(remainingPercent: 68, resetsAt: now.addingTimeInterval(2 * 3600).timeIntervalSince1970,
                        windowDurationMins: 300, kind: "primary"),
            QuotaWindow(remainingPercent: 81, resetsAt: now.addingTimeInterval(6 * 86400).timeIntervalSince1970,
                        windowDurationMins: 10080, kind: "secondary")
        ], updatedAt: now.timeIntervalSince1970, stale: false, planName: "Plus")
        let claude = ProviderQuota(windows: [
            QuotaWindow(remainingPercent: 91, resetsAt: now.addingTimeInterval(4 * 3600).timeIntervalSince1970,
                        windowDurationMins: 300, kind: "primary"),
            QuotaWindow(remainingPercent: 73, resetsAt: now.addingTimeInterval(5 * 86400).timeIntervalSince1970,
                        windowDurationMins: 10080, kind: "secondary")
        ], updatedAt: now.timeIntervalSince1970, stale: false, planName: "Max 5×")
        var snapshot = QuotaSnapshot(windows: codex.windows, updatedAt: codex.updatedAt, provider: "codex",
                             providers: ["codex": codex, "claude": claude],
                             selectedProvider: "codex", displayMode: "both", claudeEnabled: true)
        snapshot.dailyUsage = .preview
        return snapshot
    }

    var showsBoth: Bool { displayMode == "both" }

    var displayedProvider: String {
        if let displayMode, displayMode == "codex" || displayMode == "claude" { return displayMode }
        if let selectedProvider, ["codex", "claude"].contains(selectedProvider) { return selectedProvider }
        return provider == "claude" ? "claude" : "codex"
    }

    func quota(for providerID: String) -> ProviderQuota {
        if let quota = providers?[providerID] { return quota }
        if provider == providerID || (provider == nil && providerID == "codex") {
            return ProviderQuota(windows: windows, updatedAt: updatedAt, stale: nil)
        }
        return .empty
    }
}

struct QuotaEntry: TimelineEntry {
    let date: Date
    let snapshot: QuotaSnapshot

    func isStale(_ providerID: String, now: Date = Date()) -> Bool {
        let quota = snapshot.quota(for: providerID)
        return quota.stale == true ||
            (quota.updatedAt > 0 && max(date, now).timeIntervalSince1970 - quota.updatedAt > 300)
    }
}

// A reload request is not an exact timer. Scheduled entries keep expiry/reset
// states moving even when macOS delays the next network refresh.
func quotaTimelineEntries(snapshot: QuotaSnapshot, now: Date) -> [QuotaEntry] {
    var dates = Set([now])
    for minute in 1...10 { dates.insert(now.addingTimeInterval(Double(minute * 60))) }
    for minute in stride(from: 15, through: 60, by: 5) { dates.insert(now.addingTimeInterval(Double(minute * 60))) }
    for hour in 2...24 { dates.insert(now.addingTimeInterval(Double(hour * 3600))) }
    for provider in ["codex", "claude"] {
        let quota = snapshot.quota(for: provider)
        for timestamp in [quota.updatedAt + 301] + quota.windows.map(\.resetsAt) {
            let date = Date(timeIntervalSince1970: timestamp)
            if date > now && date <= now.addingTimeInterval(8 * 86400) { dates.insert(date) }
        }
    }
    return dates.sorted().map { QuotaEntry(date: $0, snapshot: snapshot) }
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
            completion(Timeline(entries: quotaTimelineEntries(snapshot: snapshot, now: now),
                                policy: .after(now.addingTimeInterval(5 * 60))))
        }.resume()
    }

    private func cachedSnapshot() -> QuotaSnapshot {
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
              let snapshot = try? JSONDecoder().decode(QuotaSnapshot.self, from: data) else { return .empty }
        return snapshot
    }
}

struct Copy {
    let language: String
    var localeIdentifier: String? = nil
    static var current: Copy {
        Copy(language: Locale.preferredLanguages.first ?? "en")
    }

    func localized(zh: String, ja: String, es: String, en: String) -> String {
        switch language.split(separator: "-").first {
        case "zh": return zh
        case "ja": return ja
        case "es": return es
        default: return en
        }
    }

    var overview: String { localized(zh: "额度概览", ja: "使用枠の概要", es: "Cuotas", en: "Usage overview") }
    var remaining: String { localized(zh: "剩余", ja: "残り", es: "Disponible", en: "Remaining") }
    var remainingQuota: String { localized(zh: "剩余额度", ja: "残りの使用枠", es: "Cuota disponible", en: "Quota remaining") }
    var fiveHour: String { localized(zh: "5 小时", ja: "5 時間", es: "5 horas", en: "5 hours") }
    var sevenDay: String { localized(zh: "7 天", ja: "7 日", es: "7 días", en: "7 days") }
    var waiting: String { localized(zh: "等待额度同步", ja: "使用枠を同期中", es: "Esperando datos", en: "Waiting for usage") }
    var unavailable: String { localized(zh: "未提供此额度", ja: "この使用枠は未提供", es: "Cuota no disponible", en: "Not provided") }
    var enableClaude: String { localized(zh: "在菜单中启用 Claude", ja: "メニューで Claude を有効化", es: "Activa Claude en el menú", en: "Enable Claude in the menu") }
    var oldData: String { localized(zh: "旧数据", ja: "前回のデータ", es: "Datos anteriores", en: "Older data") }
    var resetMissing: String { localized(zh: "暂无重置时间", ja: "リセット時刻は未提供", es: "Sin hora de reinicio", en: "No reset time yet") }
    var awaitingReset: String { localized(zh: "等待重置后同步", ja: "リセット後の同期待ち", es: "Esperando actualización", en: "Awaiting refresh") }
    var currentQuota: String { localized(zh: "当前额度", ja: "現在の使用枠", es: "Cuota actual", en: "Current quota") }
    var enableClaudeHelp: String { localized(zh: "在菜单中选择 Claude 并启用，即可查看额度。", ja: "メニューで Claude を選択して有効にしてください。", es: "Selecciona Claude en el menú y activa su cuota.", en: "Select Claude in the menu and enable usage.") }
    func connectionHelp(_ provider: String) -> String {
        localized(zh: "检查 \(provider) 登录，再从菜单立即同步。",
                  ja: "\(provider) のログインを確認し、メニューから同期してください。",
                  es: "Comprueba la sesión de \(provider) y actualiza desde el menú.",
                  en: "Check \(provider) sign-in, then refresh from the menu.")
    }
    var description: String {
        localized(zh: "小号聚焦最紧张的额度；中号同时查看 5 小时与 7 天；大号查看完整重置时间。",
                  ja: "小サイズは残り最少の枠、中サイズは 5 時間と 7 日、大サイズはリセットの詳細を表示。",
                  es: "Pequeño: cuota más limitada. Mediano: 5 horas y 7 días. Grande: reinicios detallados.",
                  en: "Small: most limited quota. Medium: 5-hour and 7-day progress. Large: complete reset details.")
    }
    var dailyTitle: String { localized(zh: "每日 Token", ja: "毎日の Token", es: "Tokens diarios", en: "Daily Tokens") }
    var dailyDescription: String { localized(zh: "查看 Codex 每日 Token 和五项官方累计指标。", ja: "Codex の日別 Token と公式の5つの指標。",
        es: "Tokens diarios de Codex y cinco métricas oficiales.", en: "Codex daily tokens and five official metrics.") }
    var dailyToday: String { localized(zh: "今天", ja: "今日", es: "Hoy", en: "Today") }
    var dailySeven: String { localized(zh: "近 7 天", ja: "過去7日", es: "Últimos 7 días", en: "Last 7 days") }
    var dailyOfficial: String { localized(zh: "Codex · 官方", ja: "Codex · 公式", es: "Codex · oficial", en: "Codex · official") }
    var dailyUnavailable: String { localized(zh: "暂无官方每日数据；打开应用刷新", ja: "公式の日別データはありません。アプリで更新してください。",
        es: "Sin datos diarios oficiales; actualiza la app.", en: "No official daily data; refresh in the app.") }
    var dailyMissingValue: String { localized(zh: "暂无数据", ja: "データなし", es: "Sin datos", en: "No data") }
    var dailyNoSeven: String { localized(zh: "近 7 天暂无数据", ja: "過去7日間のデータはありません", es: "Sin datos en 7 días", en: "No data in 7 days") }
    var dailyLifetime: String { localized(zh: "累计 Token", ja: "累計 Token", es: "Tokens totales", en: "Lifetime tokens") }
    var dailyPeak: String { localized(zh: "单日峰值", ja: "日次ピーク", es: "Pico diario", en: "Peak day") }
    var dailyLongestRun: String { localized(zh: "最长单次运行", ja: "最長の実行", es: "Sesión más larga", en: "Longest run") }
    var dailyStreak: String { localized(zh: "当前连续", ja: "現在の連続日数", es: "Racha actual", en: "Current streak") }
    var dailyLongestStreak: String { localized(zh: "最长连续", ja: "最長の連続日数", es: "Racha máxima", en: "Longest streak") }
    var dailySyncStatus: String { localized(zh: "同步状态", ja: "同期状態", es: "Sincronización", en: "Sync status") }

    func tokens(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "—" }
        let eastern = ["zh", "ja"].contains(String(language.split(separator: "-").first ?? ""))
        let thresholds: [(Double, String)] = eastern
            ? [(1e8, localized(zh: "亿", ja: "億", es: "", en: "")), (1e4, "万")]
            : [(1e9, "B"), (1e6, "M"), (1e3, "K")]
        let (divisor, suffix) = thresholds.first(where: { value >= $0.0 }) ?? (1, "")
        let number = NumberFormatter()
        number.locale = Locale(identifier: localeIdentifier ?? language)
        number.numberStyle = .decimal
        number.maximumFractionDigits = divisor == 1 ? 0 : 1
        return (number.string(from: NSNumber(value: value / divisor)) ?? "—") + suffix
    }

    func runDuration(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "—" }
        let totalMinutes = Int(seconds) / 60
        return "\(totalMinutes / 60)h \(totalMinutes % 60)m"
    }

    func streakDays(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "—" }
        let number = Int(value)
        return localized(zh: "\(number)天", ja: "\(number)日", es: "\(number)d", en: "\(number)d")
    }

    func label(_ window: QuotaWindow) -> String {
        if window.manual == true {
            var automatic = window
            automatic.manual = nil
            let manual = localized(zh: "手动", ja: "手動", es: "manual", en: "manual")
            return "\(label(automatic)) · \(manual)"
        }
        if window.isFiveHour { return fiveHour }
        if window.isSevenDay { return sevenDay }
        guard window.windowDurationMins > 0 else { return currentQuota }
        let formatter = DateComponentsFormatter()
        var calendar = Calendar.current
        calendar.locale = Locale(identifier: language)
        formatter.calendar = calendar
        formatter.allowedUnits = window.windowDurationMins < 60 ? [.minute] : [.day, .hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter.string(from: window.windowDurationMins * 60) ?? currentQuota
    }

    func date(_ timestamp: TimeInterval, full: Bool = false) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: localeIdentifier ?? language)
        formatter.setLocalizedDateFormatFromTemplate(full ? "yMdjm" : "Mdjm")
        return formatter.string(from: Date(timeIntervalSince1970: timestamp))
    }

    func resetAt(_ timestamp: TimeInterval) -> String {
        let text = date(timestamp)
        return localized(zh: "\(text) 重置", ja: "\(text) リセット", es: "Reinicio \(text)", en: "Resets \(text)")
    }

    func updated(_ timestamp: TimeInterval) -> String {
        guard timestamp > 0 else { return waiting }
        let time = updatedTime(timestamp)
        return localized(zh: "更新于 \(time)", ja: "\(time) 更新", es: "Actualizado \(time)", en: "Updated \(time)")
    }

    func updatedTime(_ timestamp: TimeInterval) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: localeIdentifier ?? language)
        formatter.setLocalizedDateFormatFromTemplate("jm")
        return formatter.string(from: Date(timeIntervalSince1970: timestamp))
    }

    func countdown(_ timestamp: TimeInterval, now: Date) -> String {
        let seconds = Int(timestamp - now.timeIntervalSince1970)
        guard seconds > 0 else { return awaitingReset }
        let days = seconds / 86400
        let hours = seconds % 86400 / 3600
        let minutes = seconds % 3600 / 60
        let zh = days > 0 ? "\(days)天" + (hours > 0 ? "\(hours)小时" : "")
            : hours > 0 ? "\(hours)小时" + (minutes > 0 ? "\(minutes)分" : "") : "\(max(1, minutes))分钟"
        let ja = days > 0 ? "\(days)日" + (hours > 0 ? "\(hours)時間" : "")
            : hours > 0 ? "\(hours)時間" + (minutes > 0 ? "\(minutes)分" : "") : "\(max(1, minutes))分"
        let short = days > 0 ? "\(days)d" + (hours > 0 ? " \(hours)h" : "")
            : hours > 0 ? "\(hours)h" + (minutes > 0 ? " \(minutes)m" : "") : "\(max(1, minutes))m"
        return localized(zh: "\(zh)后重置", ja: "\(ja)後にリセット", es: "Reinicio en \(short)", en: "Resets in \(short)")
    }
}

private struct PreviewTintKey: EnvironmentKey {
    static let defaultValue = false
}
extension EnvironmentValues {
    var quotaPreviewTinted: Bool {
        get { self[PreviewTintKey.self] }
        set { self[PreviewTintKey.self] = newValue }
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

private struct ProviderAccent {
    let providerID: String
    func color(dark: Bool) -> Color {
        if providerID == "claude" {
            return dark ? Color(red: 0.92, green: 0.64, blue: 0.48) : Color(red: 0.70, green: 0.36, blue: 0.25)
        }
        return dark ? Color(red: 0.40, green: 0.80, blue: 0.70) : Color(red: 0.12, green: 0.48, blue: 0.41)
    }
}

// Shared geometry is deliberately independent of rendering and safe for malformed snapshots.
enum QuotaRingMetrics {
    static func fraction(_ percent: Double) -> Double {
        percent.isFinite ? min(100, max(0, percent)) / 100 : 0
    }
    static func lineWidth(_ diameter: CGFloat) -> CGFloat { min(6, max(3, diameter * 0.055)) }
}

private struct QuotaRing: View {
    @Environment(\.widgetRenderingMode) private var renderingMode
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.quotaPreviewTinted) private var previewTinted
    let percent: Double
    let providerID: String
    var diameter: CGFloat = 64
    var subtitle: String? = nil

    private var tint: Color {
        renderingMode == .fullColor && !previewTinted
            ? ProviderAccent(providerID: providerID).color(dark: colorScheme == .dark) : .primary
    }

    var body: some View {
        let fraction = QuotaRingMetrics.fraction(percent)
        let lineWidth = QuotaRingMetrics.lineWidth(diameter)
        ZStack {
            Circle().stroke(.primary.opacity(0.10), lineWidth: lineWidth)
                .accessibilityHidden(true)
            if fraction > 0 {
                Circle().trim(from: 0, to: fraction)
                    .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .widgetAccentable()
                    .accessibilityHidden(true)
            }
            VStack(spacing: 2) {
                Percentage(value: fraction * 100, size: diameter * 0.28)
                if let subtitle {
                    Text(subtitle).font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .padding(lineWidth / 2)
        .frame(width: diameter, height: diameter)
        .accessibilityElement(children: .combine)
    }
}

private struct QuotaBarsKey: EnvironmentKey { static let defaultValue = true }
private extension EnvironmentValues {
    var quotaUsesBars: Bool {
        get { self[QuotaBarsKey.self] }
        set { self[QuotaBarsKey.self] = newValue }
    }
}

private struct QuotaProgress: View {
    @Environment(\.widgetRenderingMode) private var renderingMode
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.quotaPreviewTinted) private var previewTinted
    let percent: Double
    let providerID: String
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.10))
                Capsule().fill(renderingMode == .fullColor && !previewTinted
                    ? ProviderAccent(providerID: providerID).color(dark: colorScheme == .dark) : .primary)
                    .frame(width: geometry.size.width * QuotaRingMetrics.fraction(percent))
                    .widgetAccentable()
            }
        }
        .frame(height: 4).accessibilityHidden(true)
    }
}

private struct Percentage: View {
    let value: Double?
    let size: CGFloat
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 1) {
            Text(value.map { "\(Int($0.rounded()))" } ?? "—")
                .font(.system(size: size, weight: .semibold, design: .rounded))
                .monospacedDigit()
            if value != nil {
                Text("%").font(.system(size: size * 0.56, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.78))
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.85)
        .fixedSize(horizontal: true, vertical: true)
    }
}

private struct ProviderHeading: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.widgetRenderingMode) private var renderingMode
    @Environment(\.quotaPreviewTinted) private var previewTinted
    let providerID: String
    let trailing: String
    let stale: Bool
    var planName: String? = nil
    var compact: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(renderingMode == .fullColor && !previewTinted
                      ? ProviderAccent(providerID: providerID).color(dark: colorScheme == .dark) : .primary)
                .frame(width: 5, height: 5)
                .widgetAccentable()
            Text(providerID == "claude" ? "Claude" : "Codex")
                .font(.system(size: 13, weight: .semibold))
                .layoutPriority(1)
            if let planName {
                Text(planName)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.8)
                    .layoutPriority(1)
            }
            Spacer(minLength: 3)
            if stale {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 9, weight: .medium))
                    .help(trailing)
                    .accessibilityLabel(trailing)
            }
            if !compact || !stale {
                Text(trailing)
                .font(.system(size: 9, weight: .medium))
                .lineLimit(1)
                .foregroundStyle(.primary.opacity(0.82))
            }
        }
    }
}

private struct PeriodRow: View {
    @Environment(\.quotaUsesBars) private var usesBars
    let window: QuotaWindow
    let providerID: String
    let copy: Copy
    let now: Date
    var diameter: CGFloat = 44

    var body: some View {
        if usesBars {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(copy.label(window)).font(.system(size: 11, weight: .medium))
                    Spacer(minLength: 3)
                    Percentage(value: window.safePercent, size: 23)
                }
                QuotaProgress(percent: window.safePercent, providerID: providerID)
                Text(window.resetsAt > 0 ? (window.resetsAt <= now.timeIntervalSince1970 ? copy.awaitingReset : copy.resetAt(window.resetsAt)) : copy.resetMissing)
                    .font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            .accessibilityElement(children: .combine)
        } else {
        HStack(spacing: 8) {
            QuotaRing(percent: window.safePercent, providerID: providerID, diameter: diameter)
            VStack(alignment: .leading, spacing: 4) {
                Text(copy.label(window)).font(.system(size: 11, weight: .medium))
                Text(window.resetsAt > 0
                     ? (window.resetsAt <= now.timeIntervalSince1970 ? copy.awaitingReset : copy.resetAt(window.resetsAt))
                     : copy.resetMissing)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(2).minimumScaleFactor(0.9)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        }
    }
}

private struct ProviderEmpty: View {
    let title: String
    let help: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11, weight: .semibold))
            Text(help).font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }
}

private struct CompactProvider: View {
    @Environment(\.quotaUsesBars) private var usesBars
    let providerID: String
    let quota: ProviderQuota
    let stale: Bool
    let copy: Copy
    let now: Date
    let emptyText: String

    var body: some View {
        if usesBars, let window = quota.mostConstrained {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(providerID == "claude" ? "Claude" : "Codex").font(.system(size: 11, weight: .semibold))
                    Spacer(minLength: 2)
                    Percentage(value: window.safePercent, size: 23)
                }
                QuotaProgress(percent: window.safePercent, providerID: providerID)
                Text("\(copy.label(window)) · \(stale ? copy.oldData : window.resetsAt > 0 ? copy.countdown(window.resetsAt, now: now) : copy.resetMissing)")
                    .font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.78)
            }
            .frame(height: 48).accessibilityElement(children: .combine)
        } else {
        HStack(spacing: 8) {
            if let window = quota.mostConstrained {
                QuotaRing(percent: window.safePercent, providerID: providerID, diameter: 44)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(providerID == "claude" ? "Claude" : "Codex")
                    .font(.system(size: 11, weight: .semibold))
                if let window = quota.mostConstrained {
                    Text(copy.label(window)).font(.system(size: 9, weight: .medium))
                    Text(stale ? copy.oldData : window.resetsAt > 0 ? copy.countdown(window.resetsAt, now: now) : copy.resetMissing)
                        .font(.system(size: 8.5, weight: .medium))
                        .foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                } else {
                    Text(emptyText).font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary).lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 48)
        .accessibilityElement(children: .combine)
        }
    }
}

private struct PeriodDetail: View {
    @Environment(\.quotaUsesBars) private var usesBars
    let window: QuotaWindow
    let providerID: String
    let copy: Copy
    let now: Date
    var wide: Bool = false
    var diameter: CGFloat = 64

    private var resetDetails: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(window.resetsAt > 0 ? copy.countdown(window.resetsAt, now: now) : copy.resetMissing)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.primary.opacity(0.92))
                .lineLimit(1).minimumScaleFactor(0.8)
            if window.resetsAt > 0 {
                Text(copy.date(window.resetsAt, full: true))
                    .font(.system(size: 10))
                    .foregroundStyle(.primary.opacity(0.80))
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
        }
    }

    var body: some View {
        Group {
            if usesBars {
                VStack(alignment: .leading, spacing: 5) {
                    Text(copy.label(window)).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    if wide {
                        HStack(spacing: 12) {
                            Percentage(value: window.safePercent, size: 39)
                            Spacer(minLength: 4)
                            resetDetails
                        }
                        QuotaProgress(percent: window.safePercent, providerID: providerID).padding(.top, 5)
                    } else {
                        Percentage(value: window.safePercent, size: 34)
                        QuotaProgress(percent: window.safePercent, providerID: providerID).padding(.bottom, 2)
                        resetDetails
                    }
                }
            } else if wide {
                HStack(spacing: 16) {
                    QuotaRing(percent: window.safePercent, providerID: providerID, diameter: diameter)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(copy.label(window)).font(.system(size: 12, weight: .semibold))
                        resetDetails
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        QuotaRing(percent: window.safePercent, providerID: providerID, diameter: diameter)
                        Text(copy.label(window)).font(.system(size: 11, weight: .medium))
                            .lineLimit(2)
                        Spacer(minLength: 0)
                    }
                    resetDetails
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

struct QuotaWidgetContent: View {
    let entry: QuotaEntry
    let family: WidgetFamily
    private var copy: Copy { Copy(language: entry.snapshot.language ?? Locale.preferredLanguages.first ?? "en",
                                 localeIdentifier: entry.snapshot.localeIdentifier) }
    private var providers: [String] { entry.snapshot.showsBoth ? ["codex", "claude"] : [entry.snapshot.displayedProvider] }
    private var now: Date { max(entry.date, Date()) }

    private func emptyText(_ providerID: String) -> String {
        if providerID == "claude" && entry.snapshot.claudeEnabled == false { return copy.enableClaudeHelp }
        return copy.connectionHelp(providerID == "claude" ? "Claude" : "Codex")
    }

    private func emptyCard(_ providerID: String) -> some View {
        ProviderEmpty(title: providerID == "claude" && entry.snapshot.claudeEnabled == false ? copy.enableClaude : copy.waiting,
                      help: emptyText(providerID))
    }

    private func windows(_ providerID: String) -> [QuotaWindow] {
        Array(entry.snapshot.quota(for: providerID).orderedWindows.prefix(2))
    }

    private var header: some View {
        HStack(spacing: 6) {
            GaugeMark().frame(width: family == .systemSmall ? 15 : 19, height: family == .systemSmall ? 15 : 19)
                .accessibilityHidden(true)
            Text(copy.remainingQuota)
                .font(.system(size: family == .systemSmall ? 11 : 14, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 2)
        }
    }

    var body: some View {
        Group {
            switch family {
            case .systemSmall: small
            case .systemLarge: large
            default: medium
            }
        }
        .padding(family == .systemSmall ? 14 : family == .systemLarge ? 18 : 16)
        .environment(\.quotaUsesBars, entry.snapshot.usesBars)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 8) {
            if providers.count == 2 {
                header
                ForEach(providers, id: \.self) { providerID in
                    CompactProvider(providerID: providerID, quota: entry.snapshot.quota(for: providerID),
                                    stale: entry.isStale(providerID), copy: copy, now: now,
                                    emptyText: emptyText(providerID))
                }
            } else if let providerID = providers.first {
                let window = entry.snapshot.quota(for: providerID).mostConstrained
                ProviderHeading(providerID: providerID, trailing: entry.isStale(providerID) ? copy.oldData : "",
                                stale: entry.isStale(providerID), compact: true)
                if let window {
                    if entry.snapshot.usesBars {
                        Text(copy.label(window)).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                        Percentage(value: window.safePercent, size: 42)
                        QuotaProgress(percent: window.safePercent, providerID: providerID)
                    } else {
                    QuotaRing(percent: window.safePercent, providerID: providerID,
                              diameter: 86, subtitle: copy.label(window))
                        .frame(maxWidth: .infinity)
                    }
                    Text(window.resetsAt > 0
                         ? (window.resetsAt <= now.timeIntervalSince1970 ? copy.awaitingReset : copy.resetAt(window.resetsAt))
                         : copy.resetMissing)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.secondary).lineLimit(2).minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .multilineTextAlignment(.center)
                } else {
                    Text(emptyText(providerID)).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var medium: some View {
        Group {
            if providers.count == 2 {
                HStack(alignment: .top, spacing: 13) {
                    ForEach(Array(providers.enumerated()), id: \.element) { index, providerID in
                        if index > 0 { Rectangle().fill(.primary.opacity(0.10)).frame(width: 0.5) }
                        VStack(alignment: .leading, spacing: 8) {
                            ProviderHeading(providerID: providerID,
                                            trailing: entry.isStale(providerID) ? copy.oldData : "",
                                            stale: entry.isStale(providerID),
                                            planName: entry.snapshot.quota(for: providerID).displayPlan, compact: true)
                            if windows(providerID).isEmpty { emptyCard(providerID) }
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(Array(windows(providerID).enumerated()), id: \.offset) { _, window in
                                    PeriodRow(window: window, providerID: providerID, copy: copy, now: now,
                                              diameter: windows(providerID).count == 1 ? 60 : 44)
                                }
                            }
                            .frame(maxHeight: .infinity, alignment: .center)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } else if let providerID = providers.first {
                VStack(alignment: .leading, spacing: 10) {
                    ProviderHeading(providerID: providerID,
                                    trailing: entry.isStale(providerID) ? copy.oldData : "",
                                    stale: entry.isStale(providerID),
                                    planName: entry.snapshot.quota(for: providerID).displayPlan)
                    if windows(providerID).isEmpty { emptyCard(providerID) }
                    HStack(alignment: .top, spacing: 18) {
                        ForEach(Array(windows(providerID).enumerated()), id: \.offset) { _, window in
                            PeriodDetail(window: window, providerID: providerID, copy: copy, now: now,
                                         wide: windows(providerID).count == 1,
                                         diameter: windows(providerID).count == 1 ? 90 : 60)
                        }
                    }
                }
            }
        }
    }

    private var large: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            ForEach(Array(providers.enumerated()), id: \.element) { index, providerID in
                if index > 0 { Rectangle().fill(.primary.opacity(0.10)).frame(height: 0.5) }
                VStack(alignment: .leading, spacing: 8) {
                    ProviderHeading(providerID: providerID,
                                    trailing: entry.isStale(providerID) ? "\(copy.oldData) · \(copy.updated(entry.snapshot.quota(for: providerID).updatedAt))"
                                        : entry.snapshot.quota(for: providerID).updatedAt > 0
                                            ? copy.updated(entry.snapshot.quota(for: providerID).updatedAt) : "",
                                    stale: entry.isStale(providerID),
                                    planName: entry.snapshot.quota(for: providerID).displayPlan)
                    if windows(providerID).isEmpty { emptyCard(providerID) }
                    if providers.count == 2 {
                        HStack(alignment: .top, spacing: 18) {
                            ForEach(Array(windows(providerID).enumerated()), id: \.offset) { _, window in
                                PeriodDetail(window: window, providerID: providerID, copy: copy, now: now,
                                             wide: windows(providerID).count == 1,
                                             diameter: windows(providerID).count == 1 ? 90 : 60)
                            }
                        }
                    } else {
                        ForEach(Array(windows(providerID).enumerated()), id: \.offset) { _, window in
                            PeriodDetail(window: window, providerID: providerID, copy: copy, now: now,
                                         wide: true, diameter: windows(providerID).count == 1 ? 132 : 102)
                                .frame(maxHeight: .infinity)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }
}

private struct QuotaWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var systemColorScheme
    @Environment(\.widgetRenderingMode) private var renderingMode
    @Environment(\.quotaPreviewTinted) private var previewTinted
    let entry: QuotaEntry
    var body: some View {
        QuotaWidgetContent(entry: entry, family: family)
            .containerBackground(for: .widget) { Color(nsColor: .windowBackgroundColor) }
            .environment(\.colorScheme, entry.snapshot.resolvedColorScheme(system: systemColorScheme,
                tinted: renderingMode != .fullColor || previewTinted))
    }
}

private struct DailyTokenBar: View {
    let date: String
    let value: Double?
    let maximum: Double
    let tint: Color
    var chartHeight: CGFloat = 54
    var barWidth: CGFloat = 18
    var showsDate: Bool = true

    private var shortDate: String {
        let parts = date.split(separator: "-")
        guard parts.count == 3 else { return date }
        return "\(Int(parts[1]) ?? 0)/\(Int(parts[2]) ?? 0)"
    }

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .bottom) {
                if let value {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(tint)
                        .frame(width: barWidth, height: max(2, CGFloat(value / maximum) * chartHeight))
                        .widgetAccentable()
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: chartHeight, alignment: .bottom)
            if showsDate {
                Text(shortDate).font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(date) · \(value.map { String(Int($0)) } ?? "—") Token")
    }
}

private struct DailyMetric: View {
    let label: String
    let value: String
    var valueSize: CGFloat = 16
    var valueLines: Int = 1
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
            Text(value).font(.system(size: valueSize, weight: .semibold, design: .rounded))
                .foregroundStyle(valueSize < 12 ? Color.secondary : Color.primary)
                .monospacedDigit().lineLimit(valueLines).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

struct DailyTokenWidgetContent: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.widgetRenderingMode) private var renderingMode
    @Environment(\.quotaPreviewTinted) private var previewTinted
    let entry: QuotaEntry
    let family: WidgetFamily

    private var copy: Copy { Copy(language: entry.snapshot.language ?? Locale.preferredLanguages.first ?? "en",
                                   localeIdentifier: entry.snapshot.localeIdentifier) }
    private var usage: DailyUsageSnapshot {
        entry.snapshot.dailyUsage ?? DailyUsageSnapshot(days: [], summary: [:], latest: "", updatedAt: 0, available: false)
    }
    private var tint: Color {
        renderingMode == .fullColor && !previewTinted
            ? ProviderAccent(providerID: "codex").color(dark: colorScheme == .dark) : .primary
    }
    private var slots: [(date: String, value: Double?)] { usage.recentDays(reference: entry.date) }
    private var hasRecentValues: Bool { slots.contains { $0.value != nil } }
    private var maximum: Double { max(1, slots.compactMap(\.value).max() ?? 0) }
    private var today: Double? { usage.todayValue(reference: entry.date) }
    private var compactStatusText: String {
        guard usage.available, usage.updatedAt > 0 else { return copy.waiting }
        let time = copy.updatedTime(usage.updatedAt)
        return usage.isStale(reference: entry.date) ? "\(copy.oldData) · \(time)" : time
    }

    private func header(compact: Bool = false) -> some View {
        HStack(spacing: 6) {
            GaugeMark().frame(width: compact ? 14 : 17, height: compact ? 14 : 17).accessibilityHidden(true)
            Text(copy.dailyTitle).font(.system(size: compact ? 11 : 14, weight: .semibold)).lineLimit(1)
            Spacer(minLength: 2)
            if !compact {
                Text(copy.dailyOfficial).font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private func chart(height: CGFloat, barWidth: CGFloat, dates: Bool) -> some View {
        let hasValues = hasRecentValues
        return HStack(alignment: .top, spacing: 5) {
            VStack(alignment: .trailing, spacing: 0) {
                Text(hasValues ? copy.tokens(maximum) : "")
                Spacer(minLength: 0)
                if dates && maximum >= 2 && hasValues {
                    Text(copy.tokens(maximum / 2))
                    Spacer(minLength: 0)
                }
                Text(hasValues ? "0" : "")
            }
            .font(.system(size: dates ? 8 : 7, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1).minimumScaleFactor(0.7)
            .frame(width: dates ? 40 : 32, height: height, alignment: .trailing)
            ZStack(alignment: .top) {
                VStack(spacing: 0) {
                    if hasValues { Rectangle().fill(.primary.opacity(0.07)).frame(height: 0.5) }
                    Spacer(minLength: 0)
                    if dates && maximum >= 2 && hasValues {
                        Rectangle().fill(.primary.opacity(0.06)).frame(height: 0.5)
                        Spacer(minLength: 0)
                    }
                    Rectangle().fill(.primary.opacity(0.12)).frame(height: 0.5)
                }
                .frame(height: height)
                if hasValues {
                    HStack(alignment: .bottom, spacing: 4) {
                        ForEach(Array(slots.enumerated()), id: \.offset) { _, day in
                            DailyTokenBar(date: day.date, value: day.value, maximum: maximum, tint: tint,
                                          chartHeight: height, barWidth: barWidth, showsDate: dates)
                        }
                    }
                }
                if !hasValues {
                    Text(copy.dailyNoSeven).font(.system(size: 9)).foregroundStyle(.secondary)
                        .lineLimit(1).minimumScaleFactor(0.8).offset(y: dates ? 16 : 10)
                }
            }
        }
    }

    private var metricSummary: some View {
        VStack(alignment: .leading, spacing: 13) {
            Rectangle().fill(.primary.opacity(0.10)).frame(height: 0.5)
            HStack(alignment: .top, spacing: 10) {
                DailyMetric(label: copy.dailyLifetime, value: copy.tokens(usage.summary["lifetimeTokens"]))
                DailyMetric(label: copy.dailyPeak, value: copy.tokens(usage.summary["peakDailyTokens"]))
                DailyMetric(label: copy.dailyLongestRun, value: copy.runDuration(usage.summary["longestRunningTurnSec"]))
            }
            HStack(alignment: .top, spacing: 10) {
                DailyMetric(label: copy.dailyStreak, value: copy.streakDays(usage.summary["currentStreakDays"]))
                DailyMetric(label: copy.dailyLongestStreak, value: copy.streakDays(usage.summary["longestStreakDays"]))
                DailyMetric(label: copy.dailySyncStatus, value: compactStatusText,
                            valueSize: 10, valueLines: 2)
            }
        }
    }

    var body: some View {
        Group {
            if !usage.available {
                unavailable
            } else {
                switch family {
                case .systemSmall: small
                case .systemMedium: medium
                default: large
                }
            }
        }
        .padding(family == .systemSmall ? 14 : family == .systemMedium ? 15 : 17)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var unavailable: some View {
        VStack(alignment: .leading, spacing: 8) {
            header(compact: family == .systemSmall)
            Spacer(minLength: 8)
            HStack {
                Spacer(minLength: 0)
                VStack(spacing: 10) {
                    Image(systemName: "chart.bar.xaxis")
                        .font(.system(size: family == .systemSmall ? 22 : 32, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text(copy.dailyUnavailable)
                        .font(.system(size: family == .systemSmall ? 10 : 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            Spacer(minLength: 8)
        }
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 7) {
            header(compact: true)
            Text(copy.dailyToday).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            Text(today == nil ? copy.dailyMissingValue : copy.tokens(today))
                .font(.system(size: today == nil ? 13 : 27, weight: today == nil ? .medium : .semibold, design: .rounded))
                .foregroundStyle(today == nil ? Color.secondary : Color.primary)
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.75)
            Spacer(minLength: 0)
            chart(height: 35, barWidth: 9, dates: false)
            Text(usage.available ? copy.dailySeven : copy.waiting)
                .font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private var medium: some View {
        VStack(alignment: .leading, spacing: 7) {
            header()
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(copy.dailyToday).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                    Text(today == nil ? copy.dailyMissingValue : copy.tokens(today))
                        .font(.system(size: today == nil ? 13 : 27, weight: today == nil ? .medium : .semibold, design: .rounded))
                        .foregroundStyle(today == nil ? Color.secondary : Color.primary)
                        .monospacedDigit().lineLimit(1).minimumScaleFactor(0.65)
                    Text("\(copy.dailyLifetime)  \(copy.tokens(usage.summary["lifetimeTokens"]))")
                        .font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
                        .lineLimit(1).minimumScaleFactor(0.75)
                }
                .frame(width: 112, alignment: .leading)
                VStack(alignment: .leading, spacing: 5) {
                    Text(copy.dailySeven).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                    chart(height: 52, barWidth: 12, dates: true)
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                Text("\(copy.dailyPeak) \(copy.tokens(usage.summary["peakDailyTokens"]))")
                Spacer(minLength: 2)
                Text(usage.available ? copy.updated(usage.updatedAt) : copy.waiting)
            }
            .font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private var large: some View {
        VStack(alignment: .leading, spacing: 7) {
            header()
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(copy.dailyToday).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Text(today == nil ? copy.dailyMissingValue : copy.tokens(today))
                    .font(.system(size: today == nil ? 12 : 29, weight: today == nil ? .medium : .semibold, design: .rounded))
                    .foregroundStyle(today == nil ? Color.secondary : Color.primary)
                    .monospacedDigit().lineLimit(1).minimumScaleFactor(0.75)
                Spacer(minLength: 1)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(copy.dailySeven).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                chart(height: hasRecentValues ? 116 : 54, barWidth: 18, dates: hasRecentValues)
            }
            .padding(.top, 10)
            metricSummary
                .padding(.top, 8)
            Spacer(minLength: 0)
        }
    }
}

private struct DailyTokenWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var systemColorScheme
    @Environment(\.widgetRenderingMode) private var renderingMode
    @Environment(\.quotaPreviewTinted) private var previewTinted
    let entry: QuotaEntry
    var body: some View {
        DailyTokenWidgetContent(entry: entry, family: family)
            .containerBackground(for: .widget) { Color(nsColor: .windowBackgroundColor) }
            .environment(\.colorScheme, entry.snapshot.resolvedColorScheme(system: systemColorScheme,
                tinted: renderingMode != .fullColor || previewTinted))
            .widgetURL(WidgetRoute.dailyTokens)
    }
}

#if !WIDGET_PREVIEW
struct CodexQuotaWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: quotaWidgetKind, provider: QuotaProvider()) { entry in
            QuotaWidgetView(entry: entry)
        }
        .configurationDisplayName("AgentReadout")
        .description(Copy.current.description)
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}

struct CodexDailyTokenWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: dailyWidgetKind, provider: QuotaProvider()) { entry in
            DailyTokenWidgetView(entry: entry)
        }
        .configurationDisplayName(Copy.current.dailyTitle)
        .description(Copy.current.dailyDescription)
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}

@main
struct GaugeWidgetBundle: WidgetBundle {
    var body: some Widget {
        CodexQuotaWidget()
        CodexDailyTokenWidget()
    }
}
#endif
