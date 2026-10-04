import Foundation

@main
struct WidgetRegressionTests {
    static func main() throws {
        var failures = 0, count = 0
        func check(_ value: Bool, _ name: String) {
            count += 1
            if !value { failures += 1 }
            print("\(value ? "PASS" : "FAIL") \(name)")
        }
        func window(_ minutes: Double) -> QuotaWindow {
            QuotaWindow(remainingPercent: 42, resetsAt: 0, windowDurationMins: minutes, kind: "primary")
        }
        check(WidgetRoute.dailyTokens.absoluteString == "gaugeforcodex://insights/daily-token",
              "Daily Token widget has a direct statistics destination")
        check(window(300).isFiveHour, "five-hour exact period")
        check(QuotaRingMetrics.fraction(0) == 0, "zero quota has no colored arc")
        check(QuotaRingMetrics.fraction(100) == 1, "full quota closes the ring")
        check(QuotaRingMetrics.fraction(1) == 0.01, "low quota retains its actual fraction")
        check(QuotaRingMetrics.fraction(-1) == 0 && QuotaRingMetrics.fraction(101) == 1, "quota geometry clamps to valid bounds")
        check(QuotaRingMetrics.fraction(.nan) == 0 && QuotaRingMetrics.fraction(.infinity) == 0, "nonfinite quota cannot break drawing")
        check(window(10080).isSevenDay, "seven-day exact period")
        check(!window(60).isFiveHour && !window(360).isFiveHour, "other short periods are not five-hour")
        check(!window(43200).isSevenDay, "monthly quota is not weekly")
        let manual = ProviderQuota(windows: [window(0)], updatedAt: 1, stale: false)
        check(manual.orderedWindows.count == 1 && manual.mostConstrained?.safePercent == 42, "manual quota retained")
        check(Copy(language: "zh-Hans").label(window(0)) == "当前额度", "manual quota does not say zero hours")
        var explicitManual = window(10080)
        explicitManual.manual = true
        check(Copy(language: "zh-Hans").label(explicitManual) == "7 天 · 手动", "manual period provenance shown in native widget")
        let manualData = try! JSONEncoder().encode(explicitManual)
        check((try! JSONDecoder().decode(QuotaWindow.self, from: manualData)).manual == true, "manual provenance survives widget cache roundtrip")
        check(Copy(language: "en").label(window(60)) != "5 hours", "other durations retain their own label")
        let now = Date()
        var snapshot = QuotaSnapshot.preview
        let entry = QuotaEntry(date: now.addingTimeInterval(-600), snapshot: QuotaSnapshot(
            windows: [window(300)], updatedAt: now.timeIntervalSince1970 - 600, provider: "codex",
            providers: nil, selectedProvider: "codex", displayMode: "codex", claudeEnabled: false))
        check(entry.isStale("codex", now: now), "delayed entry ages into stale state")
        let timeline = quotaTimelineEntries(snapshot: snapshot, now: now)
        check(timeline.count > 24 && timeline.count < 64, "bounded future timeline")
        check(zip(timeline, timeline.dropFirst()).allSatisfy { $0.date < $1.date }, "timeline ordered with no duplicates")
        check(timeline.contains { $0.date.timeIntervalSince1970 == snapshot.quota(for: "codex").updatedAt + 301 }, "scheduled staleness transition")
        check(timeline.contains { $0.date.timeIntervalSince1970 == snapshot.quota(for: "codex").windows[0].resetsAt }, "scheduled reset transition")
        check(timeline.last!.isStale("codex", now: now), "future entries carry stale status")
        snapshot.localeIdentifier = "en_GB"
        let decoded = try JSONDecoder().decode(QuotaSnapshot.self, from: JSONEncoder().encode(snapshot))
        check(decoded.usesBars, "older snapshots default to progress bars")
        snapshot.quotaStyle = "bar"
        let barSnapshot = try JSONDecoder().decode(QuotaSnapshot.self, from: JSONEncoder().encode(snapshot))
        check(barSnapshot.usesBars, "bar style survives native widget cache round trip")
        snapshot.quotaStyle = "ring"
        let ringSnapshot = try JSONDecoder().decode(QuotaSnapshot.self, from: JSONEncoder().encode(snapshot))
        check(!ringSnapshot.usesBars, "explicit ring choice survives native widget cache round trip")
        snapshot.quotaStyle = "invalid"
        check(snapshot.usesBars, "unknown widget style uses safe bar fallback")
        snapshot.appearanceMode = "dark"
        check(snapshot.resolvedColorScheme(system: .light, tinted: false) == .dark &&
              snapshot.resolvedColorScheme(system: .light, tinted: true) == .light,
              "explicit appearance applies in full color while system tint keeps system rendering")
        snapshot.appearanceMode = "system"
        check(snapshot.resolvedColorScheme(system: .dark, tinted: false) == .dark,
              "system appearance follows host theme")
        check(decoded.localeIdentifier == "en_GB", "host region preserved")
        check(decoded.quota(for: "claude").displayPlan == "Max 5×", "provider plan survives snapshot coding")
        let old = try JSONDecoder().decode(ProviderQuota.self, from: Data(#"{"windows":[],"updatedAt":0}"#.utf8))
        check(old.displayPlan == nil, "older snapshots without plans remain readable")
        let nullPlan = try JSONDecoder().decode(ProviderQuota.self, from: Data(#"{"windows":[],"updatedAt":0,"planName":null}"#.utf8))
        check(nullPlan.displayPlan == nil, "unknown membership omitted")
        let unsafe = ProviderQuota(windows: [], updatedAt: 0, stale: false, planName: "user@example.com")
        check(unsafe.displayPlan == nil, "widget rejects unrecognized plan labels")
        check(ProviderQuota(windows: [], updatedAt: 0, stale: false, planName: "Pro Lite").displayPlan == "Pro 5×",
              "legacy internal Codex label migrates to user-facing plan")
        check(ProviderQuota(windows: [], updatedAt: 0, stale: false, planName: "Pro 20×").displayPlan == "Pro 20×",
              "verified Pro 20x label retained")
        let timestamp: TimeInterval = 1767355200 // 2026-01-02 12:00 UTC
        let us = Copy(language: "en", localeIdentifier: "en_US").date(timestamp)
        let gb = Copy(language: "en", localeIdentifier: "en_GB").date(timestamp)
        check(us != gb && gb.hasPrefix("02/01"), "date ordering follows region")
        let selected = QuotaSnapshot(windows: [], updatedAt: 0, provider: "claude", providers: nil,
                                     selectedProvider: "codex", displayMode: "follow", claudeEnabled: true)
        check(selected.displayedProvider == "codex", "explicit selection wins over legacy provider")
        let todayKey = DailyUsageSnapshot.key(for: now)
        let daily = DailyUsageSnapshot(days: [DailyTokenDay(date: todayKey, value: 0)],
            summary: ["lifetimeTokens": 5_390_000_000, "currentStreakDays": 4],
            latest: todayKey, updatedAt: now.timeIntervalSince1970, available: true)
        check(daily.todayValue(reference: now) == 0 && daily.recentDays(reference: now).count == 7,
              "explicit zero and seven calendar slots are preserved")
        check(daily.recentDays(reference: now).filter { $0.value == nil }.count == 6,
              "unreported days stay unavailable rather than becoming zero")
        snapshot.dailyUsage = daily
        let dailyRoundTrip = try JSONDecoder().decode(QuotaSnapshot.self, from: JSONEncoder().encode(snapshot))
        check(dailyRoundTrip.dailyUsage?.summary["lifetimeTokens"] == 5_390_000_000,
              "daily metrics survive the widget snapshot round trip")
        check(!daily.isStale(reference: now) && daily.isStale(reference: now.addingTimeInterval(3601)),
              "daily source freshness is distinct from quota freshness")
        var failedDaily = daily
        failedDaily.stale = true
        check(failedDaily.isStale(reference: now), "failed daily refresh remains stale even when previously updated recently")
        let legacyDaily = try JSONDecoder().decode(DailyUsageSnapshot.self, from:
            Data(#"{"days":[],"summary":{},"latest":"","updatedAt":0,"available":false}"#.utf8))
        check(legacyDaily.stale == nil && !legacyDaily.available, "older daily widget snapshots remain readable")
        print("\(count) native widget tests, \(failures) failures")
        if failures > 0 { exit(1) }
    }
}
