import Foundation
import MetricKit
import os

/// Crash, hang, launch and memory reports, kept on this device (D-004).
///
/// iOS hands an app MetricKit payloads about once a day: the day's launch
/// times, peak memory and hang time, and a diagnostic for every crash, hang,
/// CPU exception and excessive disk write, with its call stack. Nothing in
/// them is note content. They are kept here, summarised in Support, and leave
/// the device only when the user shares them. No third-party SDK, no new
/// network call, no change to what the app collects.
public struct DiagnosticsRecord: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case metrics, crash, hang, cpuException, diskWriteException
    }

    public var kind: Kind
    /// When the reported period ended.
    public var date: Date
    public var appVersion: String
    /// Metrics: the day's median time from tap to first frame, in seconds.
    public var launchSeconds: Double?
    /// Metrics: the day's peak memory, in megabytes.
    public var peakMemoryMB: Double?
    /// Metrics: total hang time that day; hang: this hang's length. Seconds.
    public var hangSeconds: Double?
    /// A crash's exception type and signal, a CPU exception's CPU time: what
    /// a developer reads first. Never note content.
    public var detail: String?

    public init(
        kind: Kind, date: Date, appVersion: String, launchSeconds: Double? = nil,
        peakMemoryMB: Double? = nil, hangSeconds: Double? = nil, detail: String? = nil
    ) {
        self.kind = kind
        self.date = date
        self.appVersion = appVersion
        self.launchSeconds = launchSeconds
        self.peakMemoryMB = peakMemoryMB
        self.hangSeconds = hangSeconds
        self.detail = detail
    }
}

/// What Support shows: the last 30 days in four numbers.
public struct DiagnosticsSummary: Sendable, Equatable {
    public var crashes: Int
    public var hangs: Int
    /// Median of the daily launch medians, seconds. Nil before any arrive.
    public var launchSeconds: Double?
    /// Highest daily peak, megabytes.
    public var peakMemoryMB: Double?
    /// Days a metrics report arrived for.
    public var reportedDays: Int

    public static func of(_ records: [DiagnosticsRecord], since: Date) -> DiagnosticsSummary {
        let recent = records.filter { $0.date >= since }
        let launches = recent.compactMap(\.launchSeconds).sorted()
        return DiagnosticsSummary(
            crashes: recent.filter { $0.kind == .crash }.count,
            hangs: recent.filter { $0.kind == .hang }.count,
            launchSeconds: launches.isEmpty ? nil : launches[launches.count / 2],
            peakMemoryMB: recent.compactMap(\.peakMemoryMB).max(),
            reportedDays: recent.filter { $0.kind == .metrics }.count
        )
    }
}

/// The reports on disk: `Diagnostics/records.json` plus each payload's own
/// JSON, as iOS wrote it, for a developer to read in full.
public actor DiagnosticsLog {
    /// Reports older than this are deleted.
    public static let retention: TimeInterval = 90 * 24 * 3600
    /// And never more raw payloads than this.
    public static let maximumPayloads = 120

    private let directory: URL
    private var cached: [DiagnosticsRecord]?

    public init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Diagnostics", isDirectory: true)
    }

    private var recordsURL: URL { directory.appendingPathComponent("records.json") }

    public func records() -> [DiagnosticsRecord] {
        if let cached { return cached }
        let decoded = (try? Data(contentsOf: recordsURL))
            .flatMap { try? JSONDecoder.diagnostics.decode([DiagnosticsRecord].self, from: $0) } ?? []
        cached = decoded
        return decoded
    }

    /// Adds reports and their raw payloads, then prunes.
    public func append(_ new: [DiagnosticsRecord], payloads: [Data] = [], now: Date = .now) {
        guard !new.isEmpty || !payloads.isEmpty else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var all = records() + new
        all.removeAll { now.timeIntervalSince($0.date) > Self.retention }
        cached = all
        if let data = try? JSONEncoder.diagnostics.encode(all) {
            try? data.write(to: recordsURL, options: .atomic)
        }
        let stamp = Int(now.timeIntervalSince1970)
        for (index, payload) in payloads.enumerated() {
            let name = "payload-\(stamp)-" + String(format: "%05d", index) + ".json"
            try? payload.write(to: directory.appendingPathComponent(name), options: .atomic)
        }
        prunePayloads(now: now)
    }

    /// One file holding every report and payload, for the share sheet.
    public func exportFile() -> URL? {
        let files = payloadFiles()
        var bundle: [String: Any] = [
            "records": (try? JSONSerialization.jsonObject(
                with: JSONEncoder.diagnostics.encode(records())
            )) ?? []
        ]
        bundle["payloads"] = files.compactMap { file in
            (try? Data(contentsOf: file.url)).flatMap { try? JSONSerialization.jsonObject(with: $0) }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: bundle, options: [.prettyPrinted, .sortedKeys])
        else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ClassNotes Diagnostics.json")
        guard (try? data.write(to: url, options: .atomic)) != nil else { return nil }
        return url
    }

    /// Payload files oldest first, with when each was received (from its
    /// name, so the log's own clock decides age, not the file system's).
    private func payloadFiles() -> [(url: URL, received: Date)] {
        ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .compactMap { url -> (URL, Date)? in
                let parts = url.deletingPathExtension().lastPathComponent.split(separator: "-")
                guard parts.count == 3, parts[0] == "payload", let stamp = TimeInterval(parts[1]) else { return nil }
                return (url, Date(timeIntervalSince1970: stamp))
            }
            .sorted { ($0.1, $0.0.lastPathComponent) < ($1.1, $1.0.lastPathComponent) }
    }

    private func prunePayloads(now: Date) {
        let files = payloadFiles()
        for (index, file) in files.enumerated()
        where index < files.count - Self.maximumPayloads || now.timeIntervalSince(file.received) > Self.retention {
            try? FileManager.default.removeItem(at: file.url)
        }
    }
}

extension JSONEncoder {
    static var diagnostics: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }
}

extension JSONDecoder {
    static var diagnostics: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}

/// Receives MetricKit's payloads and files them in the log.
public final class DiagnosticsReceiver: NSObject, MXMetricManagerSubscriber, Sendable {
    private let log: DiagnosticsLog

    public init(log: DiagnosticsLog) {
        self.log = log
    }

    /// Starts listening. iOS delivers anything waiting shortly after.
    public func start() {
        MXMetricManager.shared.add(self)
    }

    public func didReceive(_ payloads: [MXMetricPayload]) {
        let records = payloads.map(Self.record(from:))
        let raw = payloads.map { $0.jsonRepresentation() }
        Task { await log.append(records, payloads: raw) }
    }

    public func didReceive(_ payloads: [MXDiagnosticPayload]) {
        let records = payloads.flatMap(Self.records(from:))
        let raw = payloads.map { $0.jsonRepresentation() }
        Task { await log.append(records, payloads: raw) }
    }

    static func record(from payload: MXMetricPayload) -> DiagnosticsRecord {
        DiagnosticsRecord(
            kind: .metrics,
            date: payload.timeStampEnd,
            appVersion: payload.latestApplicationVersion,
            launchSeconds: payload.applicationLaunchMetrics.flatMap {
                Self.median(of: $0.histogrammedTimeToFirstDraw)
            },
            peakMemoryMB: payload.memoryMetrics.map {
                $0.peakMemoryUsage.converted(to: .megabytes).value
            },
            hangSeconds: payload.applicationResponsivenessMetrics.flatMap {
                Self.total(of: $0.histogrammedApplicationHangTime)
            }
        )
    }

    static func records(from payload: MXDiagnosticPayload) -> [DiagnosticsRecord] {
        let date = payload.timeStampEnd
        var records: [DiagnosticsRecord] = []
        for crash in payload.crashDiagnostics ?? [] {
            let type = crash.exceptionType.map { "exception \($0)" }
            let signal = crash.signal.map { "signal \($0)" }
            records.append(DiagnosticsRecord(
                kind: .crash, date: date, appVersion: crash.applicationVersion,
                detail: [type, signal].compactMap { $0 }.joined(separator: ", ")
            ))
        }
        for hang in payload.hangDiagnostics ?? [] {
            records.append(DiagnosticsRecord(
                kind: .hang, date: date, appVersion: hang.applicationVersion,
                hangSeconds: hang.hangDuration.converted(to: .seconds).value
            ))
        }
        for cpu in payload.cpuExceptionDiagnostics ?? [] {
            records.append(DiagnosticsRecord(
                kind: .cpuException, date: date, appVersion: cpu.applicationVersion,
                detail: "CPU \(Int(cpu.totalCPUTime.converted(to: .seconds).value)) s"
            ))
        }
        for disk in payload.diskWriteExceptionDiagnostics ?? [] {
            records.append(DiagnosticsRecord(
                kind: .diskWriteException, date: date, appVersion: disk.applicationVersion,
                detail: "\(Int(disk.totalWritesCaused.converted(to: .megabytes).value)) MB written"
            ))
        }
        return records
    }

    /// The bucket the middle sample falls in, by its midpoint, in seconds.
    static func median(of histogram: MXHistogram<UnitDuration>) -> Double? {
        let buckets = Self.buckets(histogram)
        let total = buckets.reduce(0) { $0 + $1.count }
        guard total > 0 else { return nil }
        var seen = 0
        for bucket in buckets {
            seen += bucket.count
            if seen * 2 >= total { return bucket.mid }
        }
        return buckets.last?.mid
    }

    static func total(of histogram: MXHistogram<UnitDuration>) -> Double? {
        let buckets = Self.buckets(histogram)
        guard !buckets.isEmpty else { return nil }
        return buckets.reduce(0) { $0 + $1.mid * Double($1.count) }
    }

    private static func buckets(_ histogram: MXHistogram<UnitDuration>) -> [(mid: Double, count: Int)] {
        histogram.bucketEnumerator.compactMap { $0 as? MXHistogramBucket<UnitDuration> }.map { bucket in
            let start = bucket.bucketStart.converted(to: .seconds).value
            let end = bucket.bucketEnd.converted(to: .seconds).value
            return ((start + end) / 2, bucket.bucketCount)
        }
    }
}
