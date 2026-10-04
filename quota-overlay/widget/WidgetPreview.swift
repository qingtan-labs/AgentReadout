// Render the production SwiftUI layout without changing the user's desktop.
// Compile alongside GaugeWidget.swift with -D WIDGET_PREVIEW.
import AppKit
import SwiftUI
import WidgetKit

@main
struct WidgetPreview {
    @MainActor
    static func main() throws {
        let directory = CommandLine.arguments.dropFirst().first ?? "/private/tmp/gauge-widget-previews"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let now = Date()
        var sample = QuotaSnapshot.preview
        sample.language = "zh-Hans"
        let missingCodex = ProviderQuota(windows: [QuotaWindow(remainingPercent: 83,
            resetsAt: now.addingTimeInterval(6 * 86400).timeIntervalSince1970,
            windowDurationMins: 10080, kind: "secondary")], updatedAt: now.timeIntervalSince1970, stale: false)
        let noResetClaude = ProviderQuota(windows: [
            QuotaWindow(remainingPercent: 100, resetsAt: 0, windowDurationMins: 300, kind: "primary"),
            QuotaWindow(remainingPercent: 100, resetsAt: now.addingTimeInterval(4 * 86400).timeIntervalSince1970,
                        windowDurationMins: 10080, kind: "secondary")
        ], updatedAt: now.timeIntervalSince1970, stale: false)
        let partial = QuotaSnapshot(windows: missingCodex.windows, updatedAt: now.timeIntervalSince1970,
            provider: "codex", providers: ["codex": missingCodex, "claude": noResetClaude],
            selectedProvider: "codex", displayMode: "both", claudeEnabled: true, language: "zh-Hans")
        let empty = QuotaSnapshot(windows: [], updatedAt: 0, provider: "codex", providers: [:],
            selectedProvider: "codex", displayMode: "both", claudeEnabled: false, language: "zh-Hans")
        let single = QuotaSnapshot(windows: noResetClaude.windows, updatedAt: now.timeIntervalSince1970,
            provider: "claude", providers: ["claude": noResetClaude], selectedProvider: "claude",
            displayMode: "claude", claudeEnabled: true, language: "zh-Hans")
        func both(_ providers: [String: ProviderQuota], enabled: Bool = true) -> QuotaSnapshot {
            QuotaSnapshot(windows: providers["codex"]?.windows ?? [], updatedAt: now.timeIntervalSince1970,
                provider: "codex", providers: providers, selectedProvider: "codex", displayMode: "both",
                claudeEnabled: enabled, language: "zh-Hans")
        }
        let weeklyOnly = both(["codex": missingCodex, "claude": missingCodex])
        let disconnected = both(["codex": missingCodex], enabled: false)
        let manualQuota = ProviderQuota(windows: [QuotaWindow(remainingPercent: 65, resetsAt: 0,
            windowDurationMins: 0, kind: "manual")], updatedAt: now.timeIntervalSince1970, stale: false)
        let manual = both(["codex": manualQuota, "claude": noResetClaude])
        let longPlans = both([
            "codex": ProviderQuota(windows: sample.quota(for: "codex").windows,
                updatedAt: now.timeIntervalSince1970 - 600, stale: true, planName: "Enterprise"),
            "claude": ProviderQuota(windows: sample.quota(for: "claude").windows,
                updatedAt: now.timeIntervalSince1970 - 600, stale: true, planName: "Max 20×")
        ])
        let sizes: [(String, WidgetFamily, CGFloat, CGFloat)] = [
            ("small", .systemSmall, 164, 164), ("medium", .systemMedium, 344, 164),
            ("large", .systemLarge, 344, 344)
        ]
        let boundary = both(["codex": ProviderQuota(windows: [
            QuotaWindow(remainingPercent: 0, resetsAt: now.timeIntervalSince1970-60, windowDurationMins: 300, kind: "primary"),
            QuotaWindow(remainingPercent: 1, resetsAt: now.timeIntervalSince1970+86400, windowDurationMins: 10080, kind: "secondary")
        ], updatedAt: now.timeIntervalSince1970, stale: false), "claude": noResetClaude])
        for style in ["ring", "bar"] {
        for (name, fixture) in [("complete", sample), ("partial", partial), ("empty", empty), ("single", single),
                                 ("weekly", weeklyOnly), ("disconnected", disconnected), ("manual", manual),
                                 ("long-plans", longPlans), ("boundary", boundary)] {
            var snapshot = fixture; snapshot.quotaStyle = style
            for (sizeName, family, width, height) in sizes {
                for appearance in ["light", "dark", "tinted"] {
                    let dark = appearance != "light"
                    let background = appearance == "tinted" ? Color(red: 0.02, green: 0.52, blue: 0.84)
                        : dark ? Color(red: 0.13, green: 0.14, blue: 0.16) : .white
                    let content = QuotaWidgetContent(entry: QuotaEntry(date: now, snapshot: snapshot), family: family)
                        .environment(\.colorScheme, dark ? .dark : .light)
                        .environment(\.quotaPreviewTinted, appearance == "tinted")
                        .frame(width: width, height: height)
                        .background(background)
                        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                    let renderer = ImageRenderer(content: content)
                    renderer.scale = 2
                    guard let image = renderer.cgImage,
                          let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                        throw NSError(domain: "GaugePreview", code: 1)
                    }
                    try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(style)-\(name)-\(sizeName)-\(appearance).png"))
                }
            }
        }
        // International copy: render the longest supported language at the actual widget sizes.
        for language in ["en", "ja", "es"] {
            var localized = partial
            localized.language = language
            localized.quotaStyle = style
            for (sizeName, family, width, height) in sizes {
                let renderer = ImageRenderer(content: QuotaWidgetContent(entry: QuotaEntry(date: now, snapshot: localized), family: family)
                    .environment(\.colorScheme, .light).frame(width: width, height: height).background(.white))
                renderer.scale = 2
                guard let image = renderer.cgImage,
                      let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { continue }
                try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(style)-\(language)-\(sizeName).png"))
            }
            localized = disconnected
            localized.language = language
            localized.quotaStyle = style
            let renderer = ImageRenderer(content: QuotaWidgetContent(entry: QuotaEntry(date: now, snapshot: localized), family: .systemMedium)
                .environment(\.colorScheme, .light).frame(width: 344, height: 164).background(.white))
            renderer.scale = 2
            if let image = renderer.cgImage,
               let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
                try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(style)-\(language)-disconnected-medium.png"))
            }
        }
        }
        var sparseDaily = sample
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now) ?? now.addingTimeInterval(-86400)
        sparseDaily.dailyUsage = DailyUsageSnapshot(days: [
            DailyTokenDay(date: DailyUsageSnapshot.key(for: yesterday),
                          value: 1_240_000)
        ], summary: sample.dailyUsage?.summary ?? [:], latest: DailyUsageSnapshot.key(for: yesterday),
            updatedAt: now.timeIntervalSince1970 - 3700, available: true)
        for (name, fixture) in [("complete", sample), ("sparse", sparseDaily), ("empty", empty)] {
            for (sizeName, family, width, height) in sizes {
            for appearance in ["light", "dark", "tinted"] {
                let dark = appearance != "light"
                let background = appearance == "tinted" ? Color(red: 0.02, green: 0.52, blue: 0.84)
                    : dark ? Color(red: 0.13, green: 0.14, blue: 0.16) : .white
                let content = DailyTokenWidgetContent(entry: QuotaEntry(date: now, snapshot: fixture), family: family)
                    .environment(\.colorScheme, dark ? .dark : .light)
                    .environment(\.quotaPreviewTinted, appearance == "tinted")
                    .frame(width: width, height: height)
                    .background(background)
                    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                let renderer = ImageRenderer(content: content)
                renderer.scale = 2
                guard let image = renderer.cgImage,
                      let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                    throw NSError(domain: "GaugePreview", code: 2)
                }
                try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("daily-\(name)-\(sizeName)-\(appearance).png"))
            }
            }
        }
        print("Rendered widget layouts: \(directory)")
    }
}
