import Foundation

/// Colonne verticale de trois emplacements (haut → bas) d'une grille Skyjo.
///
/// `nil` = carte non renseignée ; `0` est une vraie valeur, distincte du vide.
/// Une colonne marquée retirée contribue 0 sans exiger ses valeurs ; les valeurs éventuellement
/// saisies sont conservées pour permettre l'annulation, mais ignorées dans le calcul.
public struct CardColumn: Codable, Sendable, Hashable {
    public static let empty = CardColumn(validatedTop: nil, middle: nil, bottom: nil, isMarkedRemoved: false)

    public private(set) var top: Int?
    public private(set) var middle: Int?
    public private(set) var bottom: Int?
    /// Colonne éliminée pendant la manche (bouton « Colonne retirée »).
    public var isMarkedRemoved: Bool

    public init(top: Int?, middle: Int?, bottom: Int?, isMarkedRemoved: Bool = false) throws(ValidationError) {
        for value in [top, middle, bottom] {
            if let value, !CardGrid.cardValues.contains(value) {
                throw ValidationError.cardValueOutOfRange(value)
            }
        }
        self.init(validatedTop: top, middle: middle, bottom: bottom, isMarkedRemoved: isMarkedRemoved)
    }

    private init(validatedTop top: Int?, middle: Int?, bottom: Int?, isMarkedRemoved: Bool) {
        self.top = top
        self.middle = middle
        self.bottom = bottom
        self.isMarkedRemoved = isMarkedRemoved
    }

    /// Valeurs haut → bas.
    public var values: [Int?] { [top, middle, bottom] }

    /// Valeur d'une rangée (0 = haut, 2 = bas) ; `nil` si vide ou rangée inexistante.
    public subscript(row: Int) -> Int? {
        switch row {
        case 0: top
        case 1: middle
        case 2: bottom
        default: nil
        }
    }

    /// Résultat de la colonne. Seule la verticale est examinée : aucune notion de ligne horizontale.
    public var outcome: ColumnOutcome {
        if isMarkedRemoved { return .markedRemoved }
        guard let top, let middle, let bottom else {
            let entered = values.compactMap { $0 }
            return .incomplete(enteredSum: entered.reduce(0, +), missingCount: CardGrid.rowCount - entered.count)
        }
        // Trois cartes identiques révélées (y compris au dernier dévoilement, y compris négatives) :
        // la colonne est retirée et ne compte pas.
        if top == middle && middle == bottom { return .identicalCards(value: top) }
        return .counted(sum: top + middle + bottom)
    }

    /// Affectation après contrôle de position et de valeur par `CardGrid`.
    mutating func assign(_ value: Int?, row: Int) {
        switch row {
        case 0: top = value
        case 1: middle = value
        case 2: bottom = value
        default: break
        }
    }

    // MARK: Codable (validation des plages au décodage)

    private enum CodingKeys: String, CodingKey {
        case top, middle, bottom, isMarkedRemoved
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let top = try container.decodeIfPresent(Int.self, forKey: .top)
        let middle = try container.decodeIfPresent(Int.self, forKey: .middle)
        let bottom = try container.decodeIfPresent(Int.self, forKey: .bottom)
        let isMarkedRemoved = try container.decodeIfPresent(Bool.self, forKey: .isMarkedRemoved) ?? false
        for value in [top, middle, bottom] {
            if let value, !CardGrid.cardValues.contains(value) {
                throw DecodingError.dataCorrupted(DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Valeur de carte hors plage : \(value)"
                ))
            }
        }
        self.init(validatedTop: top, middle: middle, bottom: bottom, isMarkedRemoved: isMarkedRemoved)
    }
}

/// Résultat d'une colonne, avec la raison à afficher.
public enum ColumnOutcome: Sendable, Hashable {
    /// Colonne comptée : somme de ses trois cartes.
    case counted(sum: Int)
    /// « 3 cartes identiques : colonne non comptée » (contribue 0).
    case identicalCards(value: Int)
    /// Colonne marquée retirée pendant la manche (contribue 0, aucun second retrait).
    case markedRemoved
    /// Carte(s) manquante(s) : la grille ne peut pas être validée.
    case incomplete(enteredSum: Int, missingCount: Int)

    /// Contribution provisoire au total affiché en direct.
    public var runningContribution: Int {
        switch self {
        case .counted(let sum): sum
        case .incomplete(let enteredSum, _): enteredSum
        case .identicalCards, .markedRemoved: 0
        }
    }

    public var missingCount: Int {
        if case .incomplete(_, let missing) = self { return missing }
        return 0
    }
}

/// Évaluation d'une grille (calcul pur, sans effet de bord).
public struct CardGridEvaluation: Sendable, Hashable {
    /// Résultats par colonne, de gauche à droite.
    public let columns: [ColumnOutcome]

    /// Total provisoire affiché en direct pendant la saisie.
    public var runningTotal: Int { columns.reduce(0) { $0 + $1.runningContribution } }
    public var missingCardCount: Int { columns.reduce(0) { $0 + $1.missingCount } }
    public var isComplete: Bool { missingCardCount == 0 }
    /// Score brut de la manche ; `nil` tant qu'une carte présente n'est pas renseignée.
    public var rawScore: Int? { isComplete ? runningTotal : nil }
}

/// Grille finale d'un joueur : 4 colonnes verticales × 3 rangées (aide au décompte, pas de simulation).
public struct CardGrid: Codable, Sendable, Hashable {
    public static let columnCount = 4
    public static let rowCount = 3
    /// Valeurs des cartes de Skyjo classique.
    public static let cardValues: ClosedRange<Int> = -2...12

    /// Toujours exactement `columnCount` colonnes (garanti par les initialiseurs et le décodage).
    public private(set) var columns: [CardColumn]

    /// Grille vide (aucune carte renseignée, aucune colonne retirée).
    public init() {
        columns = Array(repeating: CardColumn.empty, count: Self.columnCount)
    }

    public init(columns: [CardColumn]) throws(ValidationError) {
        guard columns.count == Self.columnCount else { throw ValidationError.invalidGridShape }
        self.columns = columns
    }

    /// Construit une grille à partir de 3 rangées (haut → bas) de 4 valeurs chacune.
    public init(rows: [[Int?]], removedColumns: Set<Int> = []) throws(ValidationError) {
        guard rows.count == Self.rowCount,
              rows.allSatisfy({ $0.count == Self.columnCount }),
              removedColumns.allSatisfy({ (0..<Self.columnCount).contains($0) })
        else { throw ValidationError.invalidGridShape }

        var columns: [CardColumn] = []
        for index in 0..<Self.columnCount {
            let column = try CardColumn(
                top: rows[0][index],
                middle: rows[1][index],
                bottom: rows[2][index],
                isMarkedRemoved: removedColumns.contains(index)
            )
            columns.append(column)
        }
        self.columns = columns
    }

    /// Renseigne (ou efface avec `nil`) une carte.
    public mutating func setCard(_ value: Int?, column: Int, row: Int) throws(ValidationError) {
        guard columns.indices.contains(column), (0..<Self.rowCount).contains(row) else {
            throw ValidationError.cardPositionOutOfRange(column: column, row: row)
        }
        if let value, !Self.cardValues.contains(value) {
            throw ValidationError.cardValueOutOfRange(value)
        }
        columns[column].assign(value, row: row)
    }

    /// Marque (ou démarque) une colonne entière comme retirée ; jamais une case isolée.
    public mutating func setColumnRemoved(_ isRemoved: Bool, column: Int) throws(ValidationError) {
        guard columns.indices.contains(column) else {
            throw ValidationError.cardPositionOutOfRange(column: column, row: 0)
        }
        columns[column].isMarkedRemoved = isRemoved
    }

    public func evaluate() -> CardGridEvaluation {
        CardGridEvaluation(columns: columns.map(\.outcome))
    }

    // MARK: Codable (contrôle de forme au décodage)

    private enum CodingKeys: String, CodingKey {
        case columns
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let columns = try container.decode([CardColumn].self, forKey: .columns)
        guard columns.count == Self.columnCount else {
            throw DecodingError.dataCorruptedError(
                forKey: .columns,
                in: container,
                debugDescription: "Une grille doit contenir \(Self.columnCount) colonnes."
            )
        }
        self.columns = columns
    }
}
