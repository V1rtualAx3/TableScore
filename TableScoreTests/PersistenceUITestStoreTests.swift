import Foundation
import Testing
@testable import TableScore

#if DEBUG
// Le code testé n'existe qu'en Debug (absent des binaires Release, voir scripts/ci/check-release-symbols.sh).

/// Choix du store pour le test UI de relance (`-uiTestingPersistentStore`, `-resetUITestStore`).
@Suite("Store fichier dédié aux tests UI")
struct PersistenceUITestStoreTests {
    private func context(_ arguments: [String], debug: Bool = true) -> PersistenceController.LaunchContext {
        .init(arguments: ["TableScore"] + arguments, environment: [:], isDebugBuild: debug)
    }

    @Test("Debug : -uiTestingPersistentStore sélectionne le store dédié, jamais le vrai")
    func debugSelectsDedicatedStore() {
        let storage = PersistenceController.storage(
            for: context(["-uiTesting", "-uiTestingPersistentStore"])
        )
        #expect(storage == .file(PersistenceController.uiTestStoreURL))
        #expect(PersistenceController.uiTestStoreURL != PersistenceController.defaultStoreURL)
        #expect(PersistenceController.uiTestStoreURL.lastPathComponent == PersistenceController.uiTestStoreFileName)
    }

    @Test("Debug : sans l'argument, la mémoire reste le choix de -uiTesting")
    func uiTestingStaysInMemory() {
        #expect(PersistenceController.storage(for: context(["-uiTesting"])) == .inMemory)
        #expect(PersistenceController.storage(for: context(["-uiTesting", "-resetUITestStore"])) == .inMemory)
    }

    @Test("Release : aucun argument ne détourne le stockage")
    func releaseIgnoresArguments() {
        let release = context(["-uiTesting", "-uiTestingPersistentStore", "-resetUITestStore"], debug: false)
        #expect(PersistenceController.storage(for: release) == .applicationSupport)
    }

    @Test("Réinitialisation sans effet hors Debug ou hors store dédié")
    func resetIsNoOpOutsideDedicatedStore() throws {
        // Aucun accès disque attendu : les gardes sortent avant toute suppression.
        try PersistenceController.resetUITestStoreIfRequested(
            context: context(["-uiTestingPersistentStore", "-resetUITestStore"], debug: false)
        )
        try PersistenceController.resetUITestStoreIfRequested(context: context(["-resetUITestStore"]))
    }

    @Test("removeStoreFiles supprime le store et ses fichiers annexes, sans erreur si absents")
    func removeStoreFilesDeletesSidecars() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "tablescore-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = directory.appending(path: "x.store", directoryHint: .notDirectory)
        let unrelated = directory.appending(path: "autre.txt", directoryHint: .notDirectory)
        for suffix in ["", "-wal", "-shm"] {
            #expect(FileManager.default.createFile(atPath: store.path + suffix, contents: Data([1])))
        }
        #expect(FileManager.default.createFile(atPath: unrelated.path, contents: Data([1])))

        try PersistenceController.removeStoreFiles(at: store)
        for suffix in ["", "-wal", "-shm"] {
            #expect(!FileManager.default.fileExists(atPath: store.path + suffix))
        }
        #expect(FileManager.default.fileExists(atPath: unrelated.path))

        try PersistenceController.removeStoreFiles(at: store)
    }
}
#endif
