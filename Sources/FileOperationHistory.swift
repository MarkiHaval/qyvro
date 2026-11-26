import AppKit
import Foundation

struct QyvroTransferRecord {
    let source: URL
    let destination: URL
    let move: Bool
    let replacedItemTrashURL: URL?
}

struct QyvroTrashRecord {
    let original: URL
    let trashURL: URL
}

final class QyvroFileOperationHistory {
    static let shared = QyvroFileOperationHistory()

    private final class Entry {
        let title: String
        let affectedDirectories: [URL]
        let undo: () throws -> Void
        let redo: () throws -> Void

        init(
            title: String,
            affectedDirectories: [URL],
            undo: @escaping () throws -> Void,
            redo: @escaping () throws -> Void
        ) {
            self.title = title
            self.affectedDirectories = affectedDirectories
            self.undo = undo
            self.redo = redo
        }
    }

    private let queue = DispatchQueue(label: "Qyvro.FileOperationHistory", qos: .userInitiated)
    private var undoStack: [Entry] = []
    private var redoStack: [Entry] = []
    private var isPerforming = false
    private let maximumDepth = 50

    private init() {}

    var canUndo: Bool { !isPerforming && !undoStack.isEmpty }
    var canRedo: Bool { !isPerforming && !redoStack.isEmpty }
    var undoTitle: String? { undoStack.last?.title }
    var redoTitle: String? { redoStack.last?.title }

    func recordTransfer(_ records: [QyvroTransferRecord]) {
        guard !records.isEmpty else { return }
        let state = TransferState(records: records)
        let move = records.allSatisfy(\.move)
        let title = records.count == 1
            ? (move ? "перенос «\(records[0].destination.lastPathComponent)»" : "копирование «\(records[0].destination.lastPathComponent)»")
            : (move ? "перенос \(records.count) объектов" : "копирование \(records.count) объектов")
        record(
            Entry(
                title: title,
                affectedDirectories: state.affectedDirectories,
                undo: state.undo,
                redo: state.redo
            )
        )
    }

    func recordRename(_ pairs: [(original: URL, renamed: URL)]) {
        let changed = pairs.filter {
            $0.original.standardizedFileURL != $0.renamed.standardizedFileURL
        }
        guard !changed.isEmpty else { return }
        let state = RenameState(pairs: changed)
        let title = changed.count == 1
            ? "переименование «\(changed[0].renamed.lastPathComponent)»"
            : "переименование \(changed.count) объектов"
        record(
            Entry(
                title: title,
                affectedDirectories: state.affectedDirectories,
                undo: state.undo,
                redo: state.redo
            )
        )
    }

    func recordTrash(_ records: [QyvroTrashRecord]) {
        guard !records.isEmpty else { return }
        let state = TrashState(records: records)
        let title = records.count == 1
            ? "перемещение «\(records[0].original.lastPathComponent)» в корзину"
            : "перемещение \(records.count) объектов в корзину"
        record(
            Entry(
                title: title,
                affectedDirectories: state.affectedDirectories,
                undo: state.undo,
                redo: state.redo
            )
        )
    }

    func performUndo(completion: @escaping (Result<[URL], Error>) -> Void) {
        perform(direction: .undo, completion: completion)
    }

    func performRedo(completion: @escaping (Result<[URL], Error>) -> Void) {
        perform(direction: .redo, completion: completion)
    }

    private enum Direction {
        case undo
        case redo
    }

    private func record(_ entry: Entry) {
        guard !isPerforming else { return }
        undoStack.append(entry)
        if undoStack.count > maximumDepth {
            undoStack.removeFirst(undoStack.count - maximumDepth)
        }
        redoStack.removeAll()
    }

    private func perform(
        direction: Direction,
        completion: @escaping (Result<[URL], Error>) -> Void
    ) {
        guard !isPerforming else {
            completion(.failure(QyvroHistoryError.operationInProgress))
            return
        }
        let entry: Entry?
        switch direction {
        case .undo:
            entry = undoStack.last
        case .redo:
            entry = redoStack.last
        }
        guard let entry else {
            completion(.failure(direction == .undo ? QyvroHistoryError.nothingToUndo : QyvroHistoryError.nothingToRedo))
            return
        }

        isPerforming = true
        queue.async { [weak self] in
            let result: Result<[URL], Error>
            do {
                switch direction {
                case .undo:
                    try entry.undo()
                case .redo:
                    try entry.redo()
                }
                result = .success(entry.affectedDirectories)
            } catch {
                result = .failure(error)
            }

            DispatchQueue.main.async {
                guard let self else { return }
                self.isPerforming = false
                if case .success = result {
                    switch direction {
                    case .undo:
                        _ = self.undoStack.popLast()
                        self.redoStack.append(entry)
                    case .redo:
                        _ = self.redoStack.popLast()
                        self.undoStack.append(entry)
                    }
                }
                completion(result)
            }
        }
    }
}

private enum QyvroHistoryError: LocalizedError {
    case operationInProgress
    case nothingToUndo
    case nothingToRedo
    case missingItem(URL)
    case occupiedDestination(URL)

    var errorDescription: String? {
        switch self {
        case .operationInProgress:
            return "Предыдущая файловая операция ещё выполняется."
        case .nothingToUndo:
            return "Нет файловой операции для отмены."
        case .nothingToRedo:
            return "Нет файловой операции для повтора."
        case let .missingItem(url):
            return "Объект недоступен: \(url.path). Возможно, диск или флешка отключены."
        case let .occupiedDestination(url):
            return "Нельзя безопасно продолжить: путь уже занят — \(url.path)."
        }
    }
}

private final class TransferState {
    private final class Record {
        let source: URL
        let destination: URL
        let move: Bool
        let hadReplacement: Bool
        var replacementTrashURL: URL?
        var copiedItemTrashURL: URL?

        init(_ record: QyvroTransferRecord) {
            source = record.source.standardizedFileURL
            destination = record.destination.standardizedFileURL
            move = record.move
            hadReplacement = record.replacedItemTrashURL != nil
            replacementTrashURL = record.replacedItemTrashURL?.standardizedFileURL
        }
    }

    private let records: [Record]
    private let fileManager = FileManager.default

    init(records: [QyvroTransferRecord]) {
        self.records = records.map(Record.init)
    }

    var affectedDirectories: [URL] {
        uniqueDirectories(
            records.flatMap { [$0.source.deletingLastPathComponent(), $0.destination.deletingLastPathComponent()] }
        )
    }

    func undo() throws {
        try preflightUndo()
        var completed: [Record] = []
        do {
            for record in records.reversed() {
                try undo(record)
                completed.append(record)
            }
        } catch {
            for record in completed.reversed() {
                try? redo(record)
            }
            throw error
        }
    }

    func redo() throws {
        try preflightRedo()
        var completed: [Record] = []
        do {
            for record in records {
                try redo(record)
                completed.append(record)
            }
        } catch {
            for record in completed.reversed() {
                try? undo(record)
            }
            throw error
        }
    }

    private func preflightUndo() throws {
        for record in records {
            try requireExists(record.destination)
            if record.move, fileManager.fileExists(atPath: record.source.path) {
                throw QyvroHistoryError.occupiedDestination(record.source)
            }
            if record.hadReplacement {
                guard let trashURL = record.replacementTrashURL else {
                    throw QyvroHistoryError.missingItem(record.destination)
                }
                try requireExists(trashURL)
            }
        }
    }

    private func preflightRedo() throws {
        for record in records {
            if record.move {
                try requireExists(record.source)
            } else {
                guard let trashURL = record.copiedItemTrashURL else {
                    throw QyvroHistoryError.missingItem(record.destination)
                }
                try requireExists(trashURL)
            }
            if record.hadReplacement {
                try requireExists(record.destination)
            } else if fileManager.fileExists(atPath: record.destination.path) {
                throw QyvroHistoryError.occupiedDestination(record.destination)
            }
        }
    }

    private func undo(_ record: Record) throws {
        if record.move {
            try fileManager.moveItem(at: record.destination, to: record.source)
            do {
                try restoreReplacement(for: record)
            } catch {
                try? fileManager.moveItem(at: record.source, to: record.destination)
                throw error
            }
        } else {
            var trashed: NSURL?
            try fileManager.trashItem(at: record.destination, resultingItemURL: &trashed)
            guard let trashedURL = trashed as URL? else {
                throw QyvroHistoryError.missingItem(record.destination)
            }
            record.copiedItemTrashURL = trashedURL.standardizedFileURL
            do {
                try restoreReplacement(for: record)
            } catch {
                try? fileManager.moveItem(at: trashedURL, to: record.destination)
                record.copiedItemTrashURL = nil
                throw error
            }
        }
    }

    private func redo(_ record: Record) throws {
        var newlyTrashedReplacement: URL?
        if record.hadReplacement {
            var trashed: NSURL?
            try fileManager.trashItem(at: record.destination, resultingItemURL: &trashed)
            newlyTrashedReplacement = trashed as URL?
            record.replacementTrashURL = newlyTrashedReplacement?.standardizedFileURL
        }

        do {
            if record.move {
                try fileManager.moveItem(at: record.source, to: record.destination)
            } else {
                guard let copiedTrashURL = record.copiedItemTrashURL else {
                    throw QyvroHistoryError.missingItem(record.destination)
                }
                try fileManager.moveItem(at: copiedTrashURL, to: record.destination)
                record.copiedItemTrashURL = nil
            }
        } catch {
            if let newlyTrashedReplacement,
               !fileManager.fileExists(atPath: record.destination.path) {
                try? fileManager.moveItem(at: newlyTrashedReplacement, to: record.destination)
            }
            throw error
        }
    }

    private func restoreReplacement(for record: Record) throws {
        guard record.hadReplacement else { return }
        guard let trashURL = record.replacementTrashURL else {
            throw QyvroHistoryError.missingItem(record.destination)
        }
        try fileManager.moveItem(at: trashURL, to: record.destination)
    }

    private func requireExists(_ url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else {
            throw QyvroHistoryError.missingItem(url)
        }
    }
}

private final class RenameState {
    private let pairs: [(original: URL, renamed: URL)]
    private let fileManager = FileManager.default

    init(pairs: [(original: URL, renamed: URL)]) {
        self.pairs = pairs.map {
            ($0.original.standardizedFileURL, $0.renamed.standardizedFileURL)
        }
    }

    var affectedDirectories: [URL] {
        uniqueDirectories(
            pairs.flatMap { [$0.original.deletingLastPathComponent(), $0.renamed.deletingLastPathComponent()] }
        )
    }

    func undo() throws {
        try moveBatch(pairs.map { (from: $0.renamed, to: $0.original) })
    }

    func redo() throws {
        try moveBatch(pairs.map { (from: $0.original, to: $0.renamed) })
    }

    private func moveBatch(_ moves: [(from: URL, to: URL)]) throws {
        let sourcePaths = Set(moves.map { $0.from.path })
        for move in moves {
            guard fileManager.fileExists(atPath: move.from.path) else {
                throw QyvroHistoryError.missingItem(move.from)
            }
            if fileManager.fileExists(atPath: move.to.path), !sourcePaths.contains(move.to.path) {
                throw QyvroHistoryError.occupiedDestination(move.to)
            }
        }

        var staged: [(from: URL, temporary: URL, to: URL)] = []
        do {
            for move in moves {
                let temporary = move.from.deletingLastPathComponent()
                    .appendingPathComponent(".qyvro-history-\(UUID().uuidString)")
                try fileManager.moveItem(at: move.from, to: temporary)
                staged.append((move.from, temporary, move.to))
            }
        } catch {
            for item in staged.reversed() where fileManager.fileExists(atPath: item.temporary.path) {
                try? fileManager.moveItem(at: item.temporary, to: item.from)
            }
            throw error
        }

        var finalized: [(from: URL, to: URL)] = []
        do {
            for item in staged {
                try fileManager.moveItem(at: item.temporary, to: item.to)
                finalized.append((item.from, item.to))
            }
        } catch {
            for item in finalized.reversed() where fileManager.fileExists(atPath: item.to.path) {
                try? fileManager.moveItem(at: item.to, to: item.from)
            }
            for item in staged where fileManager.fileExists(atPath: item.temporary.path) {
                try? fileManager.moveItem(at: item.temporary, to: item.from)
            }
            throw error
        }
    }
}

private final class TrashState {
    private final class Record {
        let original: URL
        var trashURL: URL

        init(_ record: QyvroTrashRecord) {
            original = record.original.standardizedFileURL
            trashURL = record.trashURL.standardizedFileURL
        }
    }

    private let records: [Record]
    private let fileManager = FileManager.default

    init(records: [QyvroTrashRecord]) {
        self.records = records.map(Record.init)
    }

    var affectedDirectories: [URL] {
        uniqueDirectories(records.map { $0.original.deletingLastPathComponent() })
    }

    func undo() throws {
        for record in records {
            guard fileManager.fileExists(atPath: record.trashURL.path) else {
                throw QyvroHistoryError.missingItem(record.trashURL)
            }
            if fileManager.fileExists(atPath: record.original.path) {
                throw QyvroHistoryError.occupiedDestination(record.original)
            }
        }

        var completed: [Record] = []
        do {
            for record in records {
                try fileManager.moveItem(at: record.trashURL, to: record.original)
                completed.append(record)
            }
        } catch {
            for record in completed.reversed() {
                var trashed: NSURL?
                if (try? fileManager.trashItem(at: record.original, resultingItemURL: &trashed)) != nil,
                   let trashedURL = trashed as URL? {
                    record.trashURL = trashedURL.standardizedFileURL
                }
            }
            throw error
        }
    }

    func redo() throws {
        for record in records {
            guard fileManager.fileExists(atPath: record.original.path) else {
                throw QyvroHistoryError.missingItem(record.original)
            }
        }

        var completed: [Record] = []
        do {
            for record in records {
                var trashed: NSURL?
                try fileManager.trashItem(at: record.original, resultingItemURL: &trashed)
                guard let trashedURL = trashed as URL? else {
                    throw QyvroHistoryError.missingItem(record.original)
                }
                record.trashURL = trashedURL.standardizedFileURL
                completed.append(record)
            }
        } catch {
            for record in completed.reversed() where fileManager.fileExists(atPath: record.trashURL.path) {
                try? fileManager.moveItem(at: record.trashURL, to: record.original)
            }
            throw error
        }
    }
}

private func uniqueDirectories(_ urls: [URL]) -> [URL] {
    var seen = Set<String>()
    return urls.compactMap {
        let standardized = $0.standardizedFileURL
        return seen.insert(standardized.path).inserted ? standardized : nil
    }
}
