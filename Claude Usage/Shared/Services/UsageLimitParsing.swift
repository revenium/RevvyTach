import Foundation

/// Parses model-scoped weekly usage limits from the generic `limits` array that Anthropic's
/// usage API returns alongside (and, for some models, instead of) the older fixed
/// `seven_day_opus`/`seven_day_sonnet` top-level keys. Shared by ClaudeAPIService and
/// AutoStartSessionService, which both parse the same response shape independently.
enum UsageLimitParsing {
    /// One of the two primary usage windows (`five_hour`, `seven_day`) exactly
    /// as the response reported it — including the case where it reported
    /// nothing at all.
    ///
    /// `percentage` is optional on purpose. Both callers used to start from a
    /// local `var percentage = 0.0` and overwrite it only when the window was
    /// present, so a response missing the window produced a confident zero and
    /// still returned success. Nothing threw, no empty state engaged, and the
    /// UI reported "0% used" about a figure nobody had received.
    struct PrimaryWindow: Equatable {
        /// Nil when the response carried no utilization for this window. A
        /// zero here means a measured zero and nothing else.
        let percentage: Double?
        /// Nil when the response carried no parseable reset time, leaving the
        /// caller to fall back to its own estimate.
        let resetTime: Date?

        /// Whether a figure was actually reported for this window.
        var isAvailable: Bool { percentage != nil }
    }

    /// Reads one primary window out of a usage response.
    /// - Parameter key: `"five_hour"` or `"seven_day"`.
    static func parsePrimaryWindow(
        from json: [String: Any],
        key: String
    ) -> PrimaryWindow {
        guard let window = json[key] as? [String: Any] else {
            return PrimaryWindow(percentage: nil, resetTime: nil)
        }
        let percentage = window["utilization"].flatMap(parseUtilizationIfAvailable(_:))
        return PrimaryWindow(
            percentage: percentage,
            resetTime: parseResetTime(window["resets_at"])
        )
    }

    /// Extracts a model's weekly usage from its legacy top-level entry when available,
    /// otherwise from the generic model-scoped limits array.
    static func parseWeeklyModelUsage(
        from json: [String: Any],
        legacyKey: String?,
        modelDisplayName: String
    ) -> (percentage: Double, resetTime: Date?)? {
        if let legacyKey,
           let legacyLimit = json[legacyKey] as? [String: Any],
           let utilization = legacyLimit["utilization"] {
            return (parseUtilization(utilization), parseResetTime(legacyLimit["resets_at"]))
        }

        return parseWeeklyScopedLimit(
            from: json["limits"] as? [[String: Any]],
            modelDisplayName: modelDisplayName
        )
    }

    /// Finds a model-scoped weekly limit entry by display name (e.g. "Opus", "Sonnet", "Fable").
    /// Entries look like:
    /// `{ "kind": "weekly_scoped", "group": "weekly", "percent": 32,
    ///    "scope": { "model": { "display_name": "Fable" } }, "resets_at": "..." }`
    /// - Returns: nil if the array is absent or no entry matches the given model name.
    static func parseWeeklyScopedLimit(
        from limits: [[String: Any]]?,
        modelDisplayName: String
    ) -> (percentage: Double, resetTime: Date?)? {
        guard let limits else { return nil }

        for limit in limits {
            if let rawKind = limit["kind"], !(rawKind is NSNull) {
                guard let kind = rawKind as? String,
                      kind.caseInsensitiveCompare("weekly_scoped") == .orderedSame else {
                    continue
                }
            }
            guard let group = limit["group"] as? String,
                  group.caseInsensitiveCompare("weekly") == .orderedSame else { continue }
            guard let scope = limit["scope"] as? [String: Any],
                  let model = scope["model"] as? [String: Any],
                  let displayName = model["display_name"] as? String,
                  displayName.caseInsensitiveCompare(modelDisplayName) == .orderedSame else { continue }
            guard let percent = limit["percent"] else { continue }

            let percentage = parseUtilization(percent)
            let resetTime = parseResetTime(limit["resets_at"])
            return (percentage, resetTime)
        }

        return nil
    }

    /// Robust utilization parser that handles Int, Double, or String types, clamped to a
    /// finite 0...100 range — the API is a first-party service but this guards against
    /// extreme/non-finite values causing a trap in downstream `Int(Double(...))` conversions.
    static func parseUtilization(_ value: Any) -> Double {
        let raw: Double
        if let intValue = value as? Int {
            raw = Double(intValue)
        } else if let doubleValue = value as? Double {
            raw = doubleValue
        } else if let stringValue = value as? String {
            let cleaned = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "%", with: "")
            raw = Double(cleaned) ?? 0.0
        } else {
            raw = 0.0
        }

        guard raw.isFinite else { return 0.0 }
        return min(max(raw, 0.0), 100.0)
    }

    /// Same parsing as `parseUtilization`, but for callers that must tell
    /// "no usable figure" apart from "measured zero" — `PrimaryWindow` in
    /// particular. `parseUtilization`'s fallback-to-zero is correct for
    /// callers with no availability concept of their own, but it is wrong
    /// here: an explicit JSON `null` (parsed by `JSONSerialization` as
    /// `NSNull`, not a missing key), a non-numeric string, or a value of the
    /// wrong type would otherwise report a confident, measured 0% for a
    /// figure the API never actually sent. A genuine `0` or `"0%"` still
    /// parses as an available measured zero; only the unparseable path
    /// changes to nil instead of 0.
    static func parseUtilizationIfAvailable(_ value: Any) -> Double? {
        if value is NSNull { return nil }

        let raw: Double
        if let intValue = value as? Int {
            raw = Double(intValue)
        } else if let doubleValue = value as? Double {
            raw = doubleValue
        } else if let stringValue = value as? String {
            let cleaned = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "%", with: "")
            guard let parsed = Double(cleaned) else { return nil }
            raw = parsed
        } else {
            return nil
        }

        guard raw.isFinite else { return nil }
        return min(max(raw, 0.0), 100.0)
    }

    private static func parseResetTime(_ value: Any?) -> Date? {
        guard let resetsAt = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: resetsAt) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: resetsAt)
    }
}
