import Foundation

public struct DisplayCandidate: Equatable, Sendable {
    public let name: String
    public let isBuiltIn: Bool

    public init(name: String, isBuiltIn: Bool) {
        self.name = name
        self.isBuiltIn = isBuiltIn
    }
}

public enum DisplaySelection {
    public static func preferredIndex(
        in candidates: [DisplayCandidate],
        preferredName: String
    ) -> Int? {
        if let exactMatch = candidates.firstIndex(where: {
            $0.name.compare(
                preferredName,
                options: [.caseInsensitive, .diacriticInsensitive]
            ) == .orderedSame
        }) {
            return exactMatch
        }

        if let partialMatch = candidates.firstIndex(where: {
            $0.name.localizedCaseInsensitiveContains(preferredName)
        }) {
            return partialMatch
        }

        return candidates.firstIndex(where: \.isBuiltIn) ?? candidates.indices.first
    }
}
