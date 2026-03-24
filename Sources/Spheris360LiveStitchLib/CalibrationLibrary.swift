import Foundation

/// Lightweight metadata for a calibration profile without loading the full data.
public struct CalibrationProfile {
    public let url: URL
    public var displayName: String  // filename stem, user-editable
    public let created: String
    public let lensInfo: String
}

/// Manages a folder of calibration JSON files with last-used tracking.
public final class CalibrationLibrary {
    private static let lastUsedKey = "lastCalibrationProfile"
    private let libraryDir: URL
    private let legacyURL: URL

    public init(projectDir: URL) {
        self.libraryDir = projectDir.appendingPathComponent("config/library")
        self.legacyURL = projectDir.appendingPathComponent("config/calibration.json")
    }

    /// Create library dir and migrate legacy calibration.json on first run.
    public func migrateIfNeeded() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: libraryDir.path) {
            try? fm.createDirectory(at: libraryDir, withIntermediateDirectories: true)
        }
        // If library is empty and legacy file exists, copy it in
        let existing = (try? fm.contentsOfDirectory(atPath: libraryDir.path))?
            .filter { $0.hasSuffix(".json") } ?? []
        if existing.isEmpty, fm.fileExists(atPath: legacyURL.path) {
            let name = makeNameFromLegacy() ?? "default_\(dateStamp()).json"
            let dest = libraryDir.appendingPathComponent(name)
            try? fm.copyItem(at: legacyURL, to: dest)
        }
    }

    /// All profiles sorted newest-first by created date.
    public func availableProfiles() -> [CalibrationProfile] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: libraryDir.path) else { return [] }
        var profiles: [CalibrationProfile] = []
        for file in files where file.hasSuffix(".json") {
            let url = libraryDir.appendingPathComponent(file)
            let meta = readMetadata(from: url)
            profiles.append(CalibrationProfile(
                url: url,
                displayName: (file as NSString).deletingPathExtension,
                created: meta.created,
                lensInfo: meta.lensInfo
            ))
        }
        return profiles.sorted { $0.created > $1.created }
    }

    /// The last profile the user selected, if it still exists.
    public func lastUsedProfile() -> CalibrationProfile? {
        guard let filename = UserDefaults.standard.string(forKey: Self.lastUsedKey) else { return nil }
        let url = libraryDir.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let meta = readMetadata(from: url)
        return CalibrationProfile(
            url: url,
            displayName: (filename as NSString).deletingPathExtension,
            created: meta.created,
            lensInfo: meta.lensInfo
        )
    }

    public func setLastUsed(_ profile: CalibrationProfile) {
        UserDefaults.standard.set(profile.url.lastPathComponent, forKey: Self.lastUsedKey)
    }

    public func load(_ profile: CalibrationProfile) throws -> CalibrationData {
        try CalibrationData.load(from: profile.url)
    }

    /// Rename a profile's file on disk. Returns the updated profile.
    public func rename(_ profile: CalibrationProfile, to newName: String) throws -> CalibrationProfile {
        let sanitized = newName.replacingOccurrences(of: "/", with: "-")
        let newFilename = sanitized.hasSuffix(".json") ? sanitized : sanitized + ".json"
        let newURL = libraryDir.appendingPathComponent(newFilename)
        try FileManager.default.moveItem(at: profile.url, to: newURL)
        // Update last-used if this was the active one
        if UserDefaults.standard.string(forKey: Self.lastUsedKey) == profile.url.lastPathComponent {
            UserDefaults.standard.set(newFilename, forKey: Self.lastUsedKey)
        }
        return CalibrationProfile(
            url: newURL,
            displayName: (newFilename as NSString).deletingPathExtension,
            created: profile.created,
            lensInfo: profile.lensInfo
        )
    }

    // MARK: - Private

    private struct Metadata {
        var created: String
        var lensInfo: String
    }

    /// Quick partial parse to extract created date and lens names without full decode.
    private func readMetadata(from url: URL) -> Metadata {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return Metadata(created: "", lensInfo: "") }

        let created = json["created"] as? String ?? ""
        var lenses: Set<String> = []
        if let cameras = json["cameras"] as? [[String: Any]] {
            for cam in cameras {
                if let lens = cam["lens"] as? String { lenses.insert(lens) }
            }
        }
        return Metadata(created: created, lensInfo: lenses.sorted().joined(separator: " + "))
    }

    private func makeNameFromLegacy() -> String? {
        guard let data = try? Data(contentsOf: legacyURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        var lenses: Set<String> = []
        if let cameras = json["cameras"] as? [[String: Any]] {
            for cam in cameras {
                if let lens = cam["lens"] as? String {
                    lenses.insert(lens.replacingOccurrences(of: " ", with: ""))
                }
            }
        }
        let lensStr = lenses.sorted().joined(separator: "-")
        return "\(lensStr)_\(dateStamp())_imported.json"
    }

    private func dateStamp() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.string(from: Date())
    }
}
