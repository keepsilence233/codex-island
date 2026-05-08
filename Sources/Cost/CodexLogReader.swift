import Foundation

/// Walks the local Codex CLI rollout files and emits a TokenEvent for every
/// turn that recorded usage. Mirrors @ccusage/codex's data path:
///   - reads from ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl
///   - tracks the most recent `turn_context.payload.model` as the active
///     model for subsequent `event_msg.token_count` events
///   - uses `last_token_usage` (per-turn delta) rather than diffing the
///     accumulating `total_token_usage`, which is a known footgun for
///     forked sessions
///
/// Per-file parse results are memoized in `~/Library/Caches/.../codex-parse-cache.v1.json`
/// keyed by (path, mtime, size). Between two 5/15/30-minute polls almost no
/// rollout file has changed, so the steady-state refresh skips re-parsing.
enum CodexLogReader {
    static func scan(lookbackDays: Int = 30) -> [TokenEvent] {
        let cutoff = Date().addingTimeInterval(-Double(lookbackDays) * 86400)
        var cache = loadCache()
        var out: [TokenEvent] = []
        var visited = Set<String>()
        var cacheChanged = false

        for entry in jsonlFiles(under: sessionsRoot(), modifiedAfter: cutoff) {
            let path = entry.url.path
            visited.insert(path)

            let cachedEvents: [CachedEvent]
            if let hit = cache.files[path], hit.matches(mtime: entry.mtime, size: entry.size) {
                cachedEvents = hit.events
            } else {
                cachedEvents = parseFile(at: entry.url)
                cache.files[path] = CachedFile(
                    mtime: entry.mtime, size: entry.size, events: cachedEvents
                )
                cacheChanged = true
            }

            for ev in cachedEvents {
                guard ev.timestamp >= cutoff else { continue }
                out.append(TokenEvent(
                    provider: .codex,
                    timestamp: ev.timestamp,
                    model: ev.model,
                    inputTokens: ev.inputTokens,
                    outputTokens: ev.outputTokens,
                    cacheCreationTokens: 0,
                    cacheReadTokens: ev.cacheReadTokens
                ))
            }
        }

        let preCount = cache.files.count
        cache.files = cache.files.filter { visited.contains($0.key) }
        if cache.files.count != preCount { cacheChanged = true }

        if cacheChanged { saveCache(cache) }
        return out
    }

    private static func sessionsRoot() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        if let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"], !codexHome.isEmpty {
            return URL(fileURLWithPath: codexHome).appendingPathComponent("sessions", isDirectory: true)
        }
        return home.appendingPathComponent(".codex/sessions", isDirectory: true)
    }

    private struct FileEntry {
        let url: URL
        let mtime: Date
        let size: Int64
    }

    private static func jsonlFiles(under root: URL, modifiedAfter cutoff: Date) -> [FileEntry] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var hits: [FileEntry] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl",
                  url.lastPathComponent.hasPrefix("rollout-") else { continue }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey])
            guard values?.isRegularFile == true,
                  let mtime = values?.contentModificationDate,
                  let size = values?.fileSize else { continue }
            if mtime < cutoff { continue }
            hits.append(FileEntry(url: url, mtime: mtime, size: Int64(size)))
        }
        return hits
    }

    /// Parse a single file end-to-end. Threads the active model through the
    /// file's lines (Codex sessions can `/model` mid-stream) and emits one
    /// CachedEvent per usage-bearing turn.
    private static func parseFile(at url: URL) -> [CachedEvent] {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return [] }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let formatterNoFractional = ISO8601DateFormatter()
        formatterNoFractional.formatOptions = [.withInternetDateTime]

        var currentModel: String?
        var out: [CachedEvent] = []

        // Manual newline split rather than `enumerateLines` — its closure
        // is escaping and can't capture our `currentModel` thread state.
        for line in text.split(whereSeparator: { $0.isNewline }) {
            guard let lineData = line.data(using: .utf8),
                  let raw = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let type = raw["type"] as? String else { continue }

            if type == "turn_context",
               let payload = raw["payload"] as? [String: Any],
               let model = payload["model"] as? String {
                currentModel = model
                continue
            }

            guard type == "event_msg",
                  let payload = raw["payload"] as? [String: Any],
                  (payload["type"] as? String) == "token_count",
                  let info = payload["info"] as? [String: Any],
                  let last = info["last_token_usage"] as? [String: Any]
            else { continue }

            let timestampString = raw["timestamp"] as? String ?? ""
            let timestamp = formatter.date(from: timestampString)
                ?? formatterNoFractional.date(from: timestampString)
                ?? Date.distantPast

            // Codex reports input_tokens INCLUDING the cached portion. Bill
            // the non-cached delta at the input rate and the cached portion
            // at the discounted cache_read rate.
            let totalInput = (last["input_tokens"] as? Int) ?? 0
            let cached = (last["cached_input_tokens"] as? Int) ?? 0
            let nonCachedInput = max(0, totalInput - cached)
            let output = (last["output_tokens"] as? Int) ?? 0

            if nonCachedInput == 0 && cached == 0 && output == 0 { continue }

            // Fall back to gpt-5.4 for sessions that emit token_count before
            // any turn_context (early Codex CLI builds did this). Better
            // approximation than billing $0.
            let model = currentModel ?? "gpt-5.4"

            out.append(CachedEvent(
                timestamp: timestamp,
                model: model,
                inputTokens: nonCachedInput,
                outputTokens: output,
                cacheReadTokens: cached
            ))
        }
        return out
    }

    // MARK: - Per-file cache

    private static let cacheVersion = 1

    private struct CachedEvent: Codable {
        let timestamp: Date
        let model: String
        let inputTokens: Int
        let outputTokens: Int
        let cacheReadTokens: Int
    }

    private struct CachedFile: Codable {
        let mtime: Date
        let size: Int64
        let events: [CachedEvent]

        func matches(mtime other: Date, size otherSize: Int64) -> Bool {
            guard size == otherSize else { return false }
            return abs(mtime.timeIntervalSinceReferenceDate - other.timeIntervalSinceReferenceDate) < 0.001
        }
    }

    private struct ParseCache: Codable {
        var version: Int
        var files: [String: CachedFile]
    }

    private static func cacheURL() -> URL? {
        let fm = FileManager.default
        guard let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let dir = caches.appendingPathComponent("dev.codexisland.CodexIsland", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("codex-parse-cache.v1.json")
    }

    private static func loadCache() -> ParseCache {
        guard let url = cacheURL(),
              let data = try? Data(contentsOf: url),
              let cache = try? JSONDecoder().decode(ParseCache.self, from: data),
              cache.version == cacheVersion
        else { return ParseCache(version: cacheVersion, files: [:]) }
        return cache
    }

    private static func saveCache(_ cache: ParseCache) {
        guard let url = cacheURL(),
              let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
