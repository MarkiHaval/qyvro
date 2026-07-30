import Cocoa

struct FPSavedTabGroup: Codable, Equatable {
    let id: UUID
    var name: String
    var paths: [String]
    var activeIndex: Int
    var updatedAt: Date
}

final class FPSavedTabGroupStore {
    static let shared = FPSavedTabGroupStore()

    private let fileManager = FileManager.default
    private let storageURL: URL
    private(set) var groups: [FPSavedTabGroup] = []

    private init() {
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.homeDirectoryForCurrentUser
        let directory = applicationSupport.appendingPathComponent("Qyvro", isDirectory: true)
        storageURL = directory.appendingPathComponent("SavedTabGroups.json")
        try? fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        load()
    }

    @discardableResult
    func save(
        name: String,
        paths: [String],
        activeIndex: Int,
        replacing id: UUID? = nil
    ) -> FPSavedTabGroup? {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPaths = paths
            .map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL.path }
            .filter { !$0.isEmpty }
        guard !normalizedName.isEmpty, !normalizedPaths.isEmpty else { return nil }

        let group = FPSavedTabGroup(
            id: id ?? UUID(),
            name: normalizedName,
            paths: normalizedPaths,
            activeIndex: min(max(activeIndex, 0), normalizedPaths.count - 1),
            updatedAt: Date()
        )
        if let index = groups.firstIndex(where: { $0.id == group.id }) {
            groups[index] = group
        } else {
            groups.append(group)
        }
        sortAndPersist()
        return group
    }

    func remove(id: UUID) {
        groups.removeAll { $0.id == id }
        persist()
    }

    func group(id: UUID) -> FPSavedTabGroup? {
        groups.first { $0.id == id }
    }

    private func load() {
        guard let data = try? Data(contentsOf: storageURL),
              let decoded = try? JSONDecoder().decode([FPSavedTabGroup].self, from: data) else {
            groups = []
            return
        }
        groups = decoded
        sortGroups()
    }

    private func sortAndPersist() {
        sortGroups()
        persist()
    }

    private func sortGroups() {
        groups.sort {
            if $0.updatedAt != $1.updatedAt {
                return $0.updatedAt > $1.updatedAt
            }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(groups) else { return }
        do {
            try data.write(to: storageURL, options: [.atomic])
        } catch {
            NSSound.beep()
        }
    }
}
