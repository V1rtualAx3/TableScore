import Foundation

// Fichiers du stockage SwiftData : emplacement dédié, classe de protection, migration depuis
// l'ancien emplacement, effacement physique et mise de côté d'un store illisible.
//
// Décisions (Lot 4, voir aussi `PersistenceController`) :
//
// - **Dossier dédié** `Library/Application Support/Store/` : il ne contient que le store
//   (`TableScore.store`, `-wal`, `-shm`, éventuel `.TableScore_SUPPORT`) et les éventuels fichiers
//   illisibles mis de côté. L'effacement physique peut ainsi renommer puis supprimer le dossier
//   entier, y compris des fichiers annexes que SQLite/Core Data créeraient sans qu'on les connaisse.
//
// - **Classe de protection** `completeUntilFirstUserAuthentication`, appliquée explicitement au
//   dossier (les fichiers qu'y crée SQLite en héritent) et aux fichiers du store déjà présents :
//   - `.complete` rendrait les fichiers illisibles quelques secondes après le verrouillage ; une
//     écriture SQLite en cours (manche enregistrée juste avant le verrouillage, point de contrôle
//     WAL, fermeture) échouerait alors, au risque d'une transaction perdue ou d'un `-wal`
//     incohérent. L'app n'a aucune activité en arrière-plan, mais elle ne maîtrise pas l'instant
//     du verrouillage.
//   - `.completeUnlessOpen` n'apporte rien ici (pas de création de fichier en arrière-plan) et
//     reste moins éprouvée avec SQLite.
//   - `completeUntilFirstUserAuthentication` : fichiers chiffrés par le système et illisibles tant
//     que l'appareil n'a pas été déverrouillé une première fois depuis son démarrage. C'est aussi la
//     classe par défaut d'iOS : l'appliquer explicitement documente le choix et garantit qu'un
//     changement de réglage par défaut ne l'affaiblirait pas. Aucun chiffrement applicatif
//     supplémentaire n'est mis en œuvre ni promis.
//   - Le simulateur n'applique pas la protection des données : seul un appareil permet de vérifier
//     l'attribut effectif (voir les tests `PersistenceStoreFilesTests`).
//
// - **Migration** depuis l'ancien emplacement `Application Support/TableScore.store` : par
//   déplacement (renommage sur le même volume, jamais de copie ni de suppression), annexes d'abord
//   et base en dernier. Tant que l'ancienne base existe et que la nouvelle n'existe pas, la
//   migration reprend au lancement suivant ; le store n'est jamais ouvert dans un état partiel.

/// Accès disque minimal du stockage. Injectable : les tests enregistrent les appels (classe de
/// protection demandée) et simulent des échecs. Implémentation réelle : `LocalStoreFileSystem`.
protocol StoreFileSystem {
    func itemExists(at url: URL) -> Bool
    /// Noms des éléments du dossier (fichiers cachés compris), sans parcours récursif.
    func itemNames(in directory: URL) throws -> [String]
    /// Crée le dossier (et ses parents) avec la classe de protection ; sans effet s'il existe.
    func createDirectory(at url: URL, protection: FileProtectionType) throws
    func setProtection(_ protection: FileProtectionType, at url: URL) throws
    /// Renommage ; échoue si la destination existe (jamais d'écrasement).
    func moveItem(at source: URL, to destination: URL) throws
    func removeItem(at url: URL) throws
}

/// `FileManager` du système.
struct LocalStoreFileSystem: StoreFileSystem {
    func itemExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    func itemNames(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path)
    }

    func createDirectory(at url: URL, protection: FileProtectionType) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: protection]
        )
    }

    func setProtection(_ protection: FileProtectionType, at url: URL) throws {
        try FileManager.default.setAttributes([.protectionKey: protection], ofItemAtPath: url.path)
    }

    func moveItem(at source: URL, to destination: URL) throws {
        try FileManager.default.moveItem(at: source, to: destination)
    }

    func removeItem(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }
}

/// Emplacement d'un store fichier. Le dossier de `storeURL` doit être **dédié** au store :
/// l'effacement physique le renomme puis le supprime en entier.
struct StoreLocation: Sendable, Hashable {
    let storeURL: URL
    /// Ancien emplacement à migrer (`Application Support/TableScore.store`), `nil` sinon.
    let legacyStoreURL: URL?

    init(storeURL: URL, legacyStoreURL: URL? = nil) {
        self.storeURL = storeURL
        self.legacyStoreURL = legacyStoreURL
    }

    var directory: URL { storeURL.deletingLastPathComponent() }
    var fileName: String { storeURL.lastPathComponent }
}

/// Opérations sur les fichiers du store. Les décisions sont des fonctions pures (noms en entrée,
/// plan en sortie) ; l'exécution passe par `StoreFileSystem`.
enum StoreFiles {
    /// Classe de protection retenue (justification en tête de fichier).
    static var protection: FileProtectionType { .completeUntilFirstUserAuthentication }

    /// Marqueur des fichiers mis de côté : `TableScore-illisible-<horodatage>.store`.
    static let setAsideMarker = "-illisible-"
    /// Marqueur du dossier en cours d'effacement : `Store.effacement-<UUID>`.
    static let erasureMarker = ".effacement-"

    // MARK: Noms (pur)

    /// Base et extension du nom du store (`TableScore` et `.store`).
    private static func split(_ storeFileName: String) -> (stem: String, dottedExtension: String) {
        let ext = (storeFileName as NSString).pathExtension
        let stem = (storeFileName as NSString).deletingPathExtension
        return (stem, ext.isEmpty ? "" : "." + ext)
    }

    /// Éléments d'un store, **base en dernier** : annexes SQLite (`-wal`, `-shm`), dossier de
    /// données externes de Core Data (`.<base>_SUPPORT`), puis la base. Ordre utilisé pour
    /// déplacer ou renommer : la base n'est jamais séparée d'un `-wal` qui la précède.
    static func storeItemNames(storeFileName: String) -> [String] {
        let (stem, _) = split(storeFileName)
        return [storeFileName + "-wal", storeFileName + "-shm", "." + stem + "_SUPPORT", storeFileName]
    }

    /// Horodatage des fichiers mis de côté (UTC, déterministe) : `20261018-153000`.
    static func setAsideStamp(for date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        func two(_ value: Int?) -> String {
            let v = value ?? 0
            return v < 10 ? "0\(v)" : "\(v)"
        }
        return "\(c.year ?? 0)\(two(c.month))\(two(c.day))-\(two(c.hour))\(two(c.minute))\(two(c.second))"
    }

    /// Nom mis de côté d'un élément du store, ou `nil` s'il n'en fait pas partie :
    /// `TableScore.store-wal` → `TableScore-illisible-<stamp>.store-wal`,
    /// `.TableScore_SUPPORT` → `.TableScore-illisible-<stamp>_SUPPORT`.
    static func setAsideName(for name: String, storeFileName: String, stamp: String) -> String? {
        let (stem, dottedExtension) = split(storeFileName)
        let renamedStem = stem + setAsideMarker + stamp
        if name == "." + stem + "_SUPPORT" {
            return "." + renamedStem + "_SUPPORT"
        }
        guard name.hasPrefix(storeFileName),
              storeItemNames(storeFileName: storeFileName).contains(name) else { return nil }
        return renamedStem + dottedExtension + String(name.dropFirst(storeFileName.count))
    }

    /// Renommages de mise de côté pour les éléments présents (base en dernier). Si un nom de
    /// destination existe déjà (deux mises de côté dans la même seconde), un suffixe `-2`, `-3`…
    /// est ajouté à l'horodatage. Ne renvoie jamais de destination existante.
    static func setAsideRenames(
        existingNames: Set<String>,
        storeFileName: String,
        date: Date
    ) -> [(from: String, to: String)] {
        let present = storeItemNames(storeFileName: storeFileName).filter(existingNames.contains)
        guard !present.isEmpty else { return [] }
        let baseStamp = setAsideStamp(for: date)
        var attempt = 1
        while true {
            let stamp = attempt == 1 ? baseStamp : "\(baseStamp)-\(attempt)"
            let renames: [(from: String, to: String)] = present.compactMap { name in
                guard let renamed = setAsideName(for: name, storeFileName: storeFileName, stamp: stamp) else { return nil }
                return (from: name, to: renamed)
            }
            if !renames.contains(where: { existingNames.contains($0.to) }) {
                return renames
            }
            attempt += 1
        }
    }

    /// Plan de migration depuis l'ancien emplacement.
    enum LegacyMigration: Equatable, Sendable {
        /// Rien à déplacer (pas d'ancienne base, ou nouvelle base déjà présente : jamais d'écrasement,
        /// l'ancienne est alors laissée intacte et effacée par « Supprimer toutes les données »).
        case nothingToMove
        /// Éléments à déplacer, dans cet ordre (base en dernier).
        case move([String])
        /// Un élément existe aux deux emplacements sans base au nouveau : état inattendu, rien
        /// n'est déplacé (aucune association d'un `-wal` étranger à une base).
        case conflict(String)
    }

    static func legacyMigration(
        legacyNames: Set<String>,
        storeNames: Set<String>,
        storeFileName: String
    ) -> LegacyMigration {
        guard legacyNames.contains(storeFileName), !storeNames.contains(storeFileName) else { return .nothingToMove }
        let toMove = storeItemNames(storeFileName: storeFileName).filter(legacyNames.contains)
        if let clash = toMove.first(where: storeNames.contains) {
            return .conflict(clash)
        }
        return .move(toMove)
    }

    /// Éléments de l'ancien emplacement à effacer avec « Supprimer toutes les données » :
    /// ancien store et fichiers illisibles mis de côté à cet endroit. Rien d'autre.
    static func legacyErasableNames(in names: [String], storeFileName: String) -> [String] {
        let (stem, _) = split(storeFileName)
        let storeItems = Set(storeItemNames(storeFileName: storeFileName))
        return names.filter { name in
            storeItems.contains(name)
                || name.hasPrefix(stem + setAsideMarker)
                || name.hasPrefix("." + stem + setAsideMarker)
        }.sorted()
    }

    /// Dossiers d'effacement abandonnés (`Store.effacement-…`) à supprimer au lancement.
    static func leftoverErasureNames(in names: [String], directoryName: String) -> [String] {
        names.filter { $0.hasPrefix(directoryName + erasureMarker) }.sorted()
    }

    // MARK: Exécution

    /// Prépare le dossier avant ouverture : création protégée, nettoyage d'un effacement
    /// interrompu, migration de l'ancien emplacement si `migrateLegacy`, protection des fichiers.
    ///
    /// Une erreur n'est levée que si le store ne peut pas être ouvert sans risque (dossier
    /// impossible à créer, migration impossible). La réapplication de la classe de protection et
    /// le nettoyage sont « au mieux » : un échec ne doit pas priver la personne de ses parties, et
    /// les fichiers gardent alors la classe par défaut d'iOS, identique. Valeur renvoyée : `true`
    /// si la classe a été appliquée sans erreur au dossier et à chaque fichier présent.
    @discardableResult
    static func prepare(
        _ location: StoreLocation,
        fileSystem: any StoreFileSystem,
        migrateLegacy: Bool = true
    ) throws(GameRepositoryError) -> Bool {
        let directory = location.directory
        do {
            try fileSystem.createDirectory(at: directory, protection: protection)
        } catch {
            throw GameRepositoryError.storageFailure(.setup, message: ErrorDiagnostics.summary(of: error))
        }
        removeLeftoverErasures(of: location, fileSystem: fileSystem)
        if migrateLegacy {
            try migrateLegacyStore(to: location, fileSystem: fileSystem)
        }
        // Le dossier existait peut-être avant (création sans effet) : classe réappliquée.
        var applied = (try? fileSystem.setProtection(protection, at: directory)) != nil
        for name in storeItemNames(storeFileName: location.fileName) {
            let item = directory.appending(path: name, directoryHint: .notDirectory)
            guard fileSystem.itemExists(at: item) else { continue }
            if (try? fileSystem.setProtection(protection, at: item)) == nil { applied = false }
        }
        return applied
    }

    private static func removeLeftoverErasures(of location: StoreLocation, fileSystem: any StoreFileSystem) {
        let parent = location.directory.deletingLastPathComponent()
        guard let names = try? fileSystem.itemNames(in: parent) else { return }
        for name in leftoverErasureNames(in: names, directoryName: location.directory.lastPathComponent) {
            try? fileSystem.removeItem(at: parent.appending(path: name, directoryHint: .isDirectory))
        }
    }

    private static func names(in directory: URL, fileSystem: any StoreFileSystem) -> Set<String> {
        guard fileSystem.itemExists(at: directory) else { return [] }
        return Set((try? fileSystem.itemNames(in: directory)) ?? [])
    }

    /// Déplace l'ancien store dans le dossier dédié (annexes d'abord, base en dernier).
    static func migrateLegacyStore(
        to location: StoreLocation,
        fileSystem: any StoreFileSystem
    ) throws(GameRepositoryError) {
        guard let legacyURL = location.legacyStoreURL else { return }
        let legacyDirectory = legacyURL.deletingLastPathComponent()
        guard legacyDirectory.standardizedFileURL != location.directory.standardizedFileURL,
              legacyURL.lastPathComponent == location.fileName else { return }
        let plan = legacyMigration(
            legacyNames: names(in: legacyDirectory, fileSystem: fileSystem),
            storeNames: names(in: location.directory, fileSystem: fileSystem),
            storeFileName: location.fileName
        )
        switch plan {
        case .nothingToMove:
            return
        case .conflict:
            throw GameRepositoryError.storageFailure(.setup, message: "LegacyStoreConflict")
        case .move(let items):
            for name in items {
                do {
                    try fileSystem.moveItem(
                        at: legacyDirectory.appending(path: name, directoryHint: .notDirectory),
                        to: location.directory.appending(path: name, directoryHint: .notDirectory)
                    )
                } catch {
                    // Pas d'ouverture : la migration reprendra (base encore à l'ancien emplacement).
                    throw GameRepositoryError.storageFailure(.setup, message: ErrorDiagnostics.summary(of: error))
                }
            }
        }
    }

    /// Met de côté un store illisible : renomme ses fichiers en
    /// `TableScore-illisible-<horodatage>.store(-wal/-shm)` **dans le même dossier** (et à l'ancien
    /// emplacement s'il en reste), sans jamais rien supprimer. Tout ou rien : en cas d'échec, les
    /// renommages déjà faits sont annulés et une erreur est levée. Renvoie le nombre d'éléments
    /// renommés (0 : aucun fichier de store présent).
    @discardableResult
    static func setAside(
        _ location: StoreLocation,
        fileSystem: any StoreFileSystem,
        date: Date
    ) throws(GameRepositoryError) -> Int {
        var directories = [location.directory]
        if let legacyURL = location.legacyStoreURL,
           legacyURL.lastPathComponent == location.fileName,
           legacyURL.deletingLastPathComponent().standardizedFileURL != location.directory.standardizedFileURL {
            directories.append(legacyURL.deletingLastPathComponent())
        }
        var done: [(from: URL, to: URL)] = []
        for directory in directories {
            let renames = setAsideRenames(
                existingNames: names(in: directory, fileSystem: fileSystem),
                storeFileName: location.fileName,
                date: date
            )
            for rename in renames {
                let source = directory.appending(path: rename.from, directoryHint: .notDirectory)
                let destination = directory.appending(path: rename.to, directoryHint: .notDirectory)
                do {
                    try fileSystem.moveItem(at: source, to: destination)
                    done.append((from: source, to: destination))
                } catch {
                    for undo in done.reversed() {
                        try? fileSystem.moveItem(at: undo.to, to: undo.from)
                    }
                    throw GameRepositoryError.storageFailure(.setup, message: ErrorDiagnostics.summary(of: error))
                }
            }
        }
        return done.count
    }

    /// Effacement physique, **store fermé** : renomme atomiquement le dossier dédié en
    /// `<dossier>.effacement-<UUID>`, y déplace les restes de l'ancien emplacement, puis le supprime.
    ///
    /// - Le renommage préalable garantit que le store recréé ensuite part d'un dossier neuf, sans
    ///   aucun fichier ancien (un `-wal` résiduel serait rejoué dans la nouvelle base), et qu'une
    ///   éventuelle connexion SQLite encore ouverte ne vise plus les nouveaux fichiers.
    /// - Supprimer les fichiers (et non les vider) supprime aussi, sur appareil, leurs clés de
    ///   chiffrement par fichier : les pages libres SQLite/WAL qui contenaient les prénoms ne sont
    ///   plus lisibles. Les sauvegardes iCloud/ordinateur déjà faites ne sont pas concernées.
    ///
    /// Renvoie `true` si tout a été supprimé, `false` si des restes subsistent (ils seront retirés
    /// au prochain lancement par `prepare`). Lève une erreur si le dossier n'a pas pu être renommé
    /// (rien n'a été effacé ; le store peut être rouvert tel quel).
    static func eraseClosedStore(
        _ location: StoreLocation,
        fileSystem: any StoreFileSystem
    ) throws(GameRepositoryError) -> Bool {
        let directory = location.directory
        let trash = directory.deletingLastPathComponent().appending(
            path: directory.lastPathComponent + erasureMarker + UUID().uuidString,
            directoryHint: .isDirectory
        )
        if fileSystem.itemExists(at: directory) {
            do {
                try fileSystem.moveItem(at: directory, to: trash)
            } catch {
                throw GameRepositoryError.storageFailure(.eraseFiles, message: ErrorDiagnostics.summary(of: error))
            }
        } else {
            do {
                try fileSystem.createDirectory(at: trash, protection: protection)
            } catch {
                throw GameRepositoryError.storageFailure(.eraseFiles, message: ErrorDiagnostics.summary(of: error))
            }
        }

        var complete = true
        if let legacyURL = location.legacyStoreURL {
            let legacyDirectory = legacyURL.deletingLastPathComponent()
            if legacyDirectory.standardizedFileURL != directory.standardizedFileURL {
                let legacyNames = (try? fileSystem.itemNames(in: legacyDirectory)) ?? []
                for name in legacyErasableNames(in: legacyNames, storeFileName: legacyURL.lastPathComponent) {
                    let source = legacyDirectory.appending(path: name, directoryHint: .notDirectory)
                    let destination = trash.appending(path: "ancien-" + name, directoryHint: .notDirectory)
                    if (try? fileSystem.moveItem(at: source, to: destination)) == nil { complete = false }
                }
            }
        }
        if (try? fileSystem.removeItem(at: trash)) == nil { complete = false }
        return complete
    }
}
