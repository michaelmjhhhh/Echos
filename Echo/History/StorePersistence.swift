import Foundation

/// Errors are surfaced by the owning observable store; no edit is reported saved on failure.
enum StorePersistenceError: LocalizedError, Equatable, Sendable {
    case unreadable(String)
    case corrupt(String)
    case writeFailed(String)
    case noBackup

    var errorDescription: String? {
        switch self {
        case .unreadable(let detail): return "Could not read saved data. \(detail)"
        case .corrupt(let detail): return "Saved data is damaged. \(detail) Recover a backup or explicitly start fresh before saving."
        case .writeFailed(let detail): return "Changes were not saved. \(detail) Retry after fixing the storage problem."
        case .noBackup: return "No readable backup is available."
        }
    }
}

/// Files are atomically replaced and the last valid version is retained. Corruption is
/// copied aside, never silently converted into an empty store or overwritten by Add.
struct StoreFile<Value: Codable> {
    let url: URL
    var backupURL: URL { url.appendingPathExtension("backup") }

    func load(preserveCorrupt: Bool = true) -> Result<Value?, StorePersistenceError> {
        guard FileManager.default.fileExists(atPath: url.path) else { return .success(nil) }
        let data: Data
        do { data = try read(url) }
        catch { return .failure(.unreadable(error.localizedDescription)) }
        do { return .success(try decoder.decode(Value.self, from: data)) }
        catch {
            guard preserveCorrupt else {
                return .failure(.corrupt("The original is preserved at \(url.path)."))
            }
            let quarantine = url.appendingPathExtension("corrupt-\(UUID().uuidString)")
            do {
                try FileManager.default.copyItem(at: url, to: quarantine)
                return .failure(.corrupt("The original is preserved; a recovery copy is at \(quarantine.path)."))
            } catch {
                return .failure(.corrupt("The original is preserved at \(url.path). A recovery copy could not be made: \(error.localizedDescription)."))
            }
        }
    }

    func backup() -> Value? {
        guard let data = try? read(backupURL) else { return nil }
        return try? decoder.decode(Value.self, from: data)
    }

    func save(_ value: Value, preservePrevious: Bool = true, clearBackup: Bool = false, purgeRecovery: Bool = false) throws {
        do {
            let manager = FileManager.default
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(value)
            if preservePrevious, manager.fileExists(atPath: url.path) {
                let previous = try read(url)
                // Validate before allowing the old bytes into the last-good backup.
                _ = try decoder.decode(Value.self, from: previous)
                if !clearBackup { try durableWrite(previous, to: backupURL) }
            }
            if clearBackup, manager.fileExists(atPath: backupURL.path) {
                try manager.removeItem(at: backupURL)
            }
            if purgeRecovery {
                let directory = url.deletingLastPathComponent()
                for recovery in try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) {
                    let name = recovery.lastPathComponent
                    guard name.hasPrefix(url.lastPathComponent + ".corrupt-") || name.hasPrefix(url.lastPathComponent + ".recovery-") else { continue }
                    if try recovery.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                        try manager.removeItem(at: recovery)
                    }
                }
            }
            try durableWrite(data, to: url)
        } catch {
            throw StorePersistenceError.writeFailed(error.localizedDescription)
        }
    }

    /// An explicit reset must preserve otherwise-unreadable bytes before replacing them.
    func preserveForRecovery() throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw StorePersistenceError.unreadable("The data path is not a regular file: \(url.path)")
        }
        try FileManager.default.copyItem(at: url, to: url.appendingPathExtension("recovery-\(UUID().uuidString)"))
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func read(_ source: URL) throws -> Data {
        let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw StorePersistenceError.unreadable("The data path is not a regular file: \(source.path)")
        }
        guard (attributes[.size] as? NSNumber)?.intValue ?? 0 <= 32 * 1_024 * 1_024 else {
            throw StorePersistenceError.unreadable("The saved file exceeds the 32 MB safety limit.")
        }
        return try Data(contentsOf: source)
    }

    private func durableWrite(_ data: Data, to destination: URL) throws {
        try data.write(to: destination, options: .atomic)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        try handle.synchronize()
    }
}
