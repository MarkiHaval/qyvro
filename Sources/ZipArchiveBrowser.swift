import Cocoa
import CryptoKit

/// Pure-Swift read-only ZIP Central Directory reader + on-demand extractor for
/// browsing `.zip` archives as virtual folders without full extraction.
struct QyvroZipEntry {
    let internalPath: String
    let name: String
    let isDirectory: Bool
    let uncompressedSize: Int64
    let modified: Date?
}

final class QyvroZipArchiveService {
    static let shared = QyvroZipArchiveService()

    private struct CachedArchive {
        let modified: Date?
        let fileSize: Int64
        let entries: [QyvroZipEntry]
    }

    private let lock = NSLock()
    private var cache: [String: CachedArchive] = [:]

    private init() {}

    func listChildren(in zipURL: URL, internalDirectory: String) -> [QyvroZipEntry] {
        let allEntries = loadAllEntries(in: zipURL)
        let prefix: String
        if internalDirectory.isEmpty {
            prefix = ""
        } else {
            prefix = internalDirectory.hasSuffix("/") ? internalDirectory : internalDirectory + "/"
        }

        var dirs: [String: QyvroZipEntry] = [:]
        var files: [QyvroZipEntry] = []

        for entry in allEntries {
            let clean = entry.internalPath
            guard clean.hasPrefix(prefix), clean.count > prefix.count else { continue }
            let remainder = String(clean.dropFirst(prefix.count))
            let trimmed = remainder.hasSuffix("/") ? String(remainder.dropLast()) : remainder
            guard !trimmed.isEmpty else { continue }

            if let slashIdx = trimmed.firstIndex(of: "/") {
                let dirName = String(trimmed[..<slashIdx])
                let dirPath = prefix + dirName + "/"
                if dirs[dirPath] == nil {
                    dirs[dirPath] = QyvroZipEntry(
                        internalPath: dirPath,
                        name: dirName,
                        isDirectory: true,
                        uncompressedSize: 0,
                        modified: entry.modified
                    )
                }
            } else if entry.isDirectory {
                let dirPath = prefix + trimmed + "/"
                if dirs[dirPath] == nil {
                    dirs[dirPath] = QyvroZipEntry(
                        internalPath: dirPath,
                        name: trimmed,
                        isDirectory: true,
                        uncompressedSize: 0,
                        modified: entry.modified
                    )
                }
            } else {
                files.append(QyvroZipEntry(
                    internalPath: clean,
                    name: trimmed,
                    isDirectory: false,
                    uncompressedSize: entry.uncompressedSize,
                    modified: entry.modified
                ))
            }
        }

        return Array(dirs.values) + files
    }

    func loadAllEntries(in zipURL: URL) -> [QyvroZipEntry] {
        let std = zipURL.standardizedFileURL
        let vals = try? std.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let mod = vals?.contentModificationDate
        let size = Int64(vals?.fileSize ?? 0)

        lock.lock()
        if let cached = cache[std.path], cached.modified == mod, cached.fileSize == size {
            lock.unlock()
            return cached.entries
        }
        lock.unlock()

        let parsed = parseCentralDirectory(at: std) ?? fallbackListWithUnzip(at: std)

        lock.lock()
        if cache.count > 16 { cache.removeAll() }
        cache[std.path] = CachedArchive(modified: mod, fileSize: size, entries: parsed)
        lock.unlock()
        return parsed
    }

    /// Reads the ZIP Central Directory directly from the tail of the archive
    /// (zero payload reads, instant even on multi-gigabyte archives).
    private func parseCentralDirectory(at url: URL) -> [QyvroZipEntry]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        guard let fileSizeU64 = try? handle.seekToEnd(), fileSizeU64 >= 22 else { return nil }
        let fileSize = Int(fileSizeU64)
        let tailLen = min(fileSize, 65_557)
        do {
            try handle.seek(toOffset: UInt64(fileSize - tailLen))
        } catch {
            return nil
        }
        guard let tailData = try? handle.read(upToCount: tailLen), tailData.count >= 22 else { return nil }

        // Locate End of Central Directory signature: 0x06054b50 (PK\x05\x06)
        var eocdOffset: Int?
        for i in stride(from: tailData.count - 22, through: 0, by: -1) {
            if tailData[i] == 0x50,
               tailData[i + 1] == 0x4b,
               tailData[i + 2] == 0x05,
               tailData[i + 3] == 0x06 {
                eocdOffset = i
                break
            }
        }
        guard let eocd = eocdOffset else { return nil }

        let cdSize = Int(readUInt32LE(tailData, offset: eocd + 12))
        let cdOffset = Int(readUInt32LE(tailData, offset: eocd + 16))
        // ZIP64 fallback if sentinel values present.
        if cdSize == 0xFFFF_FFFF || cdOffset == 0xFFFF_FFFF || cdOffset + cdSize > fileSize {
            return nil
        }

        do {
            try handle.seek(toOffset: UInt64(cdOffset))
        } catch {
            return nil
        }
        guard let cdData = try? handle.read(upToCount: cdSize), cdData.count == cdSize else { return nil }

        var entries: [QyvroZipEntry] = []
        var pos = 0
        while pos + 46 <= cdData.count {
            guard cdData[pos] == 0x50,
                  cdData[pos + 1] == 0x4b,
                  cdData[pos + 2] == 0x01,
                  cdData[pos + 3] == 0x02 else { break }

            let dosTime = readUInt16LE(cdData, offset: pos + 12)
            let dosDate = readUInt16LE(cdData, offset: pos + 14)
            let uncompSize = Int64(readUInt32LE(cdData, offset: pos + 24))
            let nameLen = Int(readUInt16LE(cdData, offset: pos + 28))
            let extraLen = Int(readUInt16LE(cdData, offset: pos + 30))
            let commentLen = Int(readUInt16LE(cdData, offset: pos + 32))

            let nameStart = pos + 46
            let nameEnd = nameStart + nameLen
            guard nameEnd <= cdData.count else { break }

            let rawNameData = cdData.subdata(in: nameStart..<nameEnd)
            let rawName = String(data: rawNameData, encoding: .utf8)
                ?? String(data: rawNameData, encoding: .macOSRoman)
                ?? ""

            pos = nameEnd + extraLen + commentLen

            let normalized = rawName
                .replacingOccurrences(of: "\\", with: "/")
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !normalized.isEmpty,
                  !normalized.hasPrefix("__MACOSX"),
                  !normalized.contains("/__MACOSX/"),
                  URL(fileURLWithPath: normalized).lastPathComponent != ".DS_Store" else {
                continue
            }

            let isDir = rawName.hasSuffix("/")
            let cleanPath = isDir ? normalized + "/" : normalized
            let baseName = URL(fileURLWithPath: normalized).lastPathComponent
            entries.append(QyvroZipEntry(
                internalPath: cleanPath,
                name: baseName,
                isDirectory: isDir,
                uncompressedSize: uncompSize,
                modified: decodeDOSDateTime(date: dosDate, time: dosTime)
            ))
        }
        return entries
    }

    private func fallbackListWithUnzip(at url: URL) -> [QyvroZipEntry] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        proc.arguments = ["-Z1", url.path]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0,
                  let output = String(data: data, encoding: .utf8) else { return [] }
            return output.split(separator: "\n").compactMap { line in
                let raw = String(line)
                let normalized = raw.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                guard !normalized.isEmpty,
                      !normalized.hasPrefix("__MACOSX"),
                      URL(fileURLWithPath: normalized).lastPathComponent != ".DS_Store" else { return nil }
                let isDir = raw.hasSuffix("/")
                return QyvroZipEntry(
                    internalPath: isDir ? normalized + "/" : normalized,
                    name: URL(fileURLWithPath: normalized).lastPathComponent,
                    isDirectory: isDir,
                    uncompressedSize: 0,
                    modified: nil
                )
            }
        } catch {
            return []
        }
    }

    /// Extracts a single entry into a clean temp preview cache for `Space` viewing or opening.
    func extractEntryToTempCache(entryPath: String, from zipURL: URL, completion: @escaping (URL?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let digest = SHA256.hash(data: Data(zipURL.standardizedFileURL.path.utf8))
            let hashPrefix = digest.prefix(6).map { String(format: "%02x", $0) }.joined()
            let cacheRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("QyvroZipCache", isDirectory: true)
                .appendingPathComponent(hashPrefix, isDirectory: true)
            let targetFile = cacheRoot.appendingPathComponent(entryPath)
            if FileManager.default.fileExists(atPath: targetFile.path) {
                DispatchQueue.main.async { completion(targetFile) }
                return
            }
            try? FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            proc.arguments = ["-oq", zipURL.path, entryPath, "-d", cacheRoot.path]
            proc.standardOutput = Pipe()
            proc.standardError = Pipe()
            do {
                try proc.run()
                proc.waitUntilExit()
                let ok = FileManager.default.fileExists(atPath: targetFile.path)
                DispatchQueue.main.async { completion(ok ? targetFile : nil) }
            } catch {
                DispatchQueue.main.async { completion(nil) }
            }
        }
    }

    /// Extracts selected entries (files or folders) into a real destination folder.
    func extractEntries(_ entryPaths: [String], from zipURL: URL, to destinationFolder: URL, completion: @escaping (Result<Int, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try FileManager.default.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
                var patterns: [String] = []
                for path in entryPaths {
                    if path.hasSuffix("/") {
                        patterns.append(path + "*")
                        patterns.append(path)
                    } else {
                        patterns.append(path)
                    }
                }
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
                proc.arguments = ["-oq", zipURL.path] + patterns + ["-d", destinationFolder.path]
                let errPipe = Pipe()
                proc.standardOutput = Pipe()
                proc.standardError = errPipe
                try proc.run()
                proc.waitUntilExit()
                if proc.terminationStatus == 0 || proc.terminationStatus == 1 {
                    DispatchQueue.main.async { completion(.success(entryPaths.count)) }
                } else {
                    let msg = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
                        ?? L("Ошибка распаковки архива.", "Archive extraction failed.")
                    DispatchQueue.main.async {
                        completion(.failure(NSError(domain: "QyvroZip", code: Int(proc.terminationStatus), userInfo: [NSLocalizedDescriptionKey: msg])))
                    }
                }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    private func readUInt16LE(_ data: Data, offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private func readUInt32LE(_ data: Data, offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    private func decodeDOSDateTime(date: UInt16, time: UInt16) -> Date? {
        guard date != 0 else { return nil }
        var comps = DateComponents()
        comps.year = Int((date >> 9) & 0x7F) + 1980
        comps.month = Int((date >> 5) & 0x0F)
        comps.day = Int(date & 0x1F)
        comps.hour = Int((time >> 11) & 0x1F)
        comps.minute = Int((time >> 5) & 0x3F)
        comps.second = Int(time & 0x1F) * 2
        return Calendar.current.date(from: comps)
    }
}
