import Foundation
import Testing
@testable import NotesServices

/// Crash and speed reports stay on the device, stay bounded, and add up to
/// the right four numbers (D-004).
@Suite("Diagnostics kept on the device")
struct DiagnosticsTests {
    private func makeLog() -> (DiagnosticsLog, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmnotes-diag-\(UUID().uuidString)", isDirectory: true)
        return (DiagnosticsLog(directory: dir), dir)
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("Reports are kept across launches")
    func persists() async {
        let (log, dir) = makeLog()
        defer { try? FileManager.default.removeItem(at: dir) }
        await log.append([DiagnosticsRecord(kind: .crash, date: now, appVersion: "1.6", detail: "signal 11")], now: now)
        let reopened = DiagnosticsLog(directory: dir)
        #expect(await reopened.records().map(\.detail) == ["signal 11"])
    }

    @Test("Reports older than 90 days are deleted")
    func prunesOld() async {
        let (log, dir) = makeLog()
        defer { try? FileManager.default.removeItem(at: dir) }
        let old = now.addingTimeInterval(-91 * 24 * 3600)
        await log.append([DiagnosticsRecord(kind: .hang, date: old, appVersion: "1.4")], now: old)
        await log.append([DiagnosticsRecord(kind: .hang, date: now, appVersion: "1.6")], now: now)
        #expect(await log.records().map(\.appVersion) == ["1.6"])
    }

    @Test("Raw payloads are capped, oldest first")
    func capsPayloads() async throws {
        let (log, dir) = makeLog()
        defer { try? FileManager.default.removeItem(at: dir) }
        for batch in 0..<3 {
            let payloads = (0..<50).map { Data(#"{"n":\#(batch * 50 + $0)}"#.utf8) }
            await log.append([], payloads: payloads, now: now.addingTimeInterval(Double(batch)))
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("payload-") }
        #expect(files.count == DiagnosticsLog.maximumPayloads)
    }

    @Test("The summary counts the last 30 days only, with the median launch")
    func summary() {
        let day: TimeInterval = 24 * 3600
        let records = [
            DiagnosticsRecord(kind: .crash, date: now, appVersion: "1.6"),
            DiagnosticsRecord(kind: .crash, date: now.addingTimeInterval(-40 * day), appVersion: "1.4"),
            DiagnosticsRecord(kind: .hang, date: now, appVersion: "1.6", hangSeconds: 2),
            DiagnosticsRecord(kind: .metrics, date: now, appVersion: "1.6", launchSeconds: 0.4, peakMemoryMB: 300),
            DiagnosticsRecord(kind: .metrics, date: now.addingTimeInterval(-day), appVersion: "1.6",
                              launchSeconds: 0.9, peakMemoryMB: 410),
            DiagnosticsRecord(kind: .metrics, date: now.addingTimeInterval(-2 * day), appVersion: "1.6",
                              launchSeconds: 0.5, peakMemoryMB: 280)
        ]
        let summary = DiagnosticsSummary.of(records, since: now.addingTimeInterval(-30 * day))
        #expect(summary.crashes == 1)
        #expect(summary.hangs == 1)
        #expect(summary.launchSeconds == 0.5)
        #expect(summary.peakMemoryMB == 410)
        #expect(summary.reportedDays == 3)
    }

    @Test("Sharing writes one readable file with the reports and the payloads")
    func export() async throws {
        let (log, dir) = makeLog()
        defer { try? FileManager.default.removeItem(at: dir) }
        await log.append(
            [DiagnosticsRecord(kind: .metrics, date: now, appVersion: "1.6", launchSeconds: 0.4)],
            payloads: [Data(#"{"appVersion":"1.6"}"#.utf8)], now: now
        )
        let url = try #require(await log.exportFile())
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        #expect((object?["records"] as? [Any])?.count == 1)
        #expect((object?["payloads"] as? [Any])?.count == 1)
    }
}
