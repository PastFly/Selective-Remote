import Foundation

/// Detect changes in the legacy Host store without applying them to either version.
enum LegacyProfileChangeDetector {
    static func hasChanges(_ defaults: any NativePreferencesAccess) throws -> Bool {
        let values = try NativeStorageMigration.legacyProfileData(defaults)
        return try profilesDiffer(values[0].0, values[0].1)
            || singleProfileDiffers(values[1].0, values[1].1)
    }

    private static func profilesDiffer(_ first: Data?, _ second: Data?) throws -> Bool {
        if first == second { return false }
        var left = try profileObjects(first)
        var right = try profileObjects(second)
        guard left.count == right.count else { return true }
        let known = Set(Mirror(reflecting: ConnectionProfile()).children.compactMap(\.label))
            .union(["redirectClipboard"])
        for index in left.indices {
            let leftUnknown = left[index].filter { !known.contains($0.key) }
            let rightUnknown = right[index].filter { !known.contains($0.key) }
            guard NSDictionary(dictionary: leftUnknown).isEqual(to: rightUnknown) else { return true }
            // Missing identity on only one side makes a comparison unsafe.
            let leftHasID = left[index]["id"] != nil && !(left[index]["id"] is NSNull)
            let rightHasID = right[index]["id"] != nil && !(right[index]["id"] is NSNull)
            guard leftHasID == rightHasID else { throw NativeStorageMigration.MigrationError.invalidSource }
            // Old records may omit fields whose decoder creates random defaults.
            // Use a stable value for comparison where both IDs are absent and
            // treat an omitted generated timestamp as its existing counterpart.
            for (key, fallback) in [
                ("id", "00000000-0000-0000-0000-000000000000" as Any),
                ("createdAt", 0 as Any)
            ] {
                let l = left[index][key], r = right[index][key]
                let value = (l is NSNull ? nil : l) ?? (r is NSNull ? nil : r) ?? fallback
                if l == nil || l is NSNull { left[index][key] = value }
                if r == nil || r is NSNull { right[index][key] = value }
            }
        }
        let decoder = JSONDecoder()
        let leftProfiles = try decoder.decode([ConnectionProfile].self, from: JSONSerialization.data(withJSONObject: left))
        let rightProfiles = try decoder.decode([ConnectionProfile].self, from: JSONSerialization.data(withJSONObject: right))
        if leftProfiles != rightProfiles { return true }
        let encoder = JSONEncoder()
        let encodedLeft = try profileObjects(encoder.encode(leftProfiles))
        let encodedRight = try profileObjects(encoder.encode(rightProfiles))
        for index in left.indices {
            for key in known where key != "redirectClipboard" {
                let leftExtras = nestedUnknownFields(left[index][key], encodedLeft[index][key])
                let rightExtras = nestedUnknownFields(right[index][key], encodedRight[index][key])
                if !NSDictionary(dictionary: leftExtras).isEqual(to: rightExtras) { return true }
            }
        }
        return false
    }

    /// Codable ignores unknown nested fields. Preserve them for comparison so
    /// an older writer cannot silently alter data this build does not decode.
    private static func nestedUnknownFields(_ raw: Any?, _ encoded: Any?) -> [String: Any] {
        if let raw = raw as? [String: Any], let encoded = encoded as? [String: Any] {
            var extras: [String: Any] = [:]
            for (key, value) in raw {
                if let encodedValue = encoded[key] {
                    let nested = nestedUnknownFields(value, encodedValue)
                    if !nested.isEmpty { extras[key] = nested }
                } else if !(value is NSNull) {
                    extras[key] = value
                }
            }
            return extras
        }
        if let raw = raw as? [Any], let encoded = encoded as? [Any], raw.count == encoded.count {
            var extras: [String: Any] = [:]
            for index in raw.indices {
                let nested = nestedUnknownFields(raw[index], encoded[index])
                if !nested.isEmpty { extras[String(index)] = nested }
            }
            return extras
        }
        return [:]
    }

    private static func profileObjects(_ data: Data?) throws -> [[String: Any]] {
        guard let data else { return [] }
        guard let values = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw NativeStorageMigration.MigrationError.invalidSource
        }
        return values
    }

    private static func singleProfileDiffers(_ first: Data?, _ second: Data?) throws -> Bool {
        if first == second { return false }
        guard let first, let second else { return true }
        guard var left = try JSONSerialization.jsonObject(with: first) as? [String: Any],
              var right = try JSONSerialization.jsonObject(with: second) as? [String: Any] else {
            throw NativeStorageMigration.MigrationError.invalidSource
        }
        let known: Set<String> = ["host", "username", "selectedDisplayIDs", "primaryDisplayID"]
        guard NSDictionary(dictionary: left.filter { !known.contains($0.key) })
            .isEqual(to: right.filter { !known.contains($0.key) }) else { return true }
        for key in ["host", "username"] {
            if left[key] == nil || left[key] is NSNull { left[key] = "" }
            if right[key] == nil || right[key] is NSNull { right[key] = "" }
        }
        if left["selectedDisplayIDs"] == nil || left["selectedDisplayIDs"] is NSNull { left["selectedDisplayIDs"] = [String]() }
        if right["selectedDisplayIDs"] == nil || right["selectedDisplayIDs"] is NSNull { right["selectedDisplayIDs"] = [String]() }
        let decoder = JSONDecoder()
        let a = try decoder.decode(LegacyConnectionProfile.self, from: JSONSerialization.data(withJSONObject: left))
        let b = try decoder.decode(LegacyConnectionProfile.self, from: JSONSerialization.data(withJSONObject: right))
        return a.host != b.host || a.username != b.username || a.selectedDisplayIDs != b.selectedDisplayIDs
            || a.primaryDisplayID != b.primaryDisplayID
    }
}
