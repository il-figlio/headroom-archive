import Foundation
import Testing
@testable import HeadroomCore

private func reading(_ account: String?, windows: [QuotaWindow] = [], error: String? = nil,
                     fetchedAt: Date = Date(timeIntervalSince1970: 1_000)) -> QuotaReading {
    var r = QuotaReading(provider: account == nil ? .codex : .claude)
    r.account = account
    r.windows = windows
    r.error = error
    r.fetchedAt = fetchedAt
    if !windows.isEmpty { r.plan = "Max" }
    return r
}

private let w = [QuotaWindow(label: "5h", usedFraction: 0.4)]

@Test func quotaMergeKeepsPreviousOnErrorOnlyAndDropsGoneSources() {
    let previous = [reading("a", windows: w), reading("b", windows: w), reading("gone", windows: w)]
    let freshB = [QuotaWindow(label: "5h", usedFraction: 0.9)]
    let fresh = [reading("b", windows: freshB, fetchedAt: Date(timeIntervalSince1970: 2_000)),
                 reading("a", error: "boom", fetchedAt: Date(timeIntervalSince1970: 2_000)),
                 reading("new", error: "nope")]
    let merged = QuotaMerge.merge(previous: previous, fresh: fresh)
    #expect(merged.map(\.id) == ["claude/b", "claude/a", "claude/new"])
    #expect(merged[0].windows == freshB && merged[0].error == nil)
    #expect(merged[1].windows == w && merged[1].plan == "Max" && merged[1].error == "boom")
    #expect(merged[1].fetchedAt == Date(timeIntervalSince1970: 1_000))
    #expect(merged[2].windows.isEmpty && merged[2].error == "nope")
}

@Test func quotaCacheSaveNeverDowngrades() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("quota-cache-\(UUID().uuidString)/quota-cache.json")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    #expect(QuotaCache.load(url).isEmpty)

    QuotaCache.save([reading("a", windows: w), reading(nil, windows: w)], to: url)
    #expect(QuotaCache.load(url).map(\.id) == ["claude/a", "codex"])

    QuotaCache.save([reading("a", error: "offline"), reading(nil, error: "offline")], to: url)
    let kept = QuotaCache.load(url)
    #expect(kept.allSatisfy { $0.windows == w && $0.error == "offline" && $0.fetchedAt == Date(timeIntervalSince1970: 1_000) })

    let newer = [QuotaWindow(label: "5h", usedFraction: 0.1)]
    QuotaCache.save([reading("a", windows: newer)], to: url)
    let replaced = QuotaCache.load(url)
    #expect(replaced.map(\.id) == ["claude/a"] && replaced[0].windows == newer && replaced[0].error == nil)

    try Data("not json".utf8).write(to: url)
    #expect(QuotaCache.load(url).isEmpty)
}

@Test func quotaStalenessResetAndMostConstrained() {
    let now = Date(timeIntervalSince1970: 100_000)
    #expect(!reading("a", windows: w, fetchedAt: now.addingTimeInterval(-60)).isStale(now: now))
    #expect(reading("a", windows: w, fetchedAt: now.addingTimeInterval(-QuotaPolicy.staleAfter - 1)).isStale(now: now))
    #expect(reading("a", windows: w, error: "x", fetchedAt: now).isStale(now: now))

    let reset = QuotaWindow(label: "5h", usedFraction: 0.95, resetsAt: now.addingTimeInterval(-1))
    let atNow = QuotaWindow(label: "x", usedFraction: 0.99, resetsAt: now)
    let week = QuotaWindow(label: "Week", usedFraction: 0.6, resetsAt: now.addingTimeInterval(3600))
    let fable = QuotaWindow(label: "Fable", usedFraction: 0.3)
    #expect(reset.hasReset(now: now) && atNow.hasReset(now: now))
    #expect(!week.hasReset(now: now) && !fable.hasReset(now: now))
    #expect(abs(week.leftFraction - 0.4) < 1e-9)
    #expect(reading("a", windows: [reset, atNow, fable, week]).mostConstrained(now: now) == week)
    #expect(reading("a", windows: [reset]).mostConstrained(now: now) == nil)
    #expect(reading("a").mostConstrained(now: now) == nil)
}
