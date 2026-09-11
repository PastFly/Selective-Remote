import Foundation

enum SelectiveRemoteHostFolderPath {
    static let maximumDepth = 8
    static let maximumComponentLength = 64
    static let maximumPathLength = 120

    static func normalize(_ value: String) -> String {
        let components = value
            .split(separator: "/", omittingEmptySubsequences: true)
            .prefix(maximumDepth)
            .map {
                String(
                    $0.trimmingCharacters(in: .whitespacesAndNewlines)
                        .prefix(maximumComponentLength)
                )
            }
            .filter { !$0.isEmpty }
        var result: [String] = []
        var remaining = maximumPathLength
        for component in components {
            let separatorLength = result.isEmpty ? 0 : 1
            guard remaining > separatorLength else { break }
            let bounded = String(component.prefix(remaining - separatorLength))
            guard !bounded.isEmpty else { break }
            result.append(bounded)
            remaining -= separatorLength + bounded.count
        }
        return result.joined(separator: "/")
    }

    static func components(_ value: String) -> [String] {
        let normalized = normalize(value)
        return normalized.isEmpty ? [] : normalized.split(separator: "/").map(String.init)
    }

    static func displayName(_ path: String) -> String {
        components(path).last
            ?? UpdateLocalization.text(ru: "Без папки", en: "No Folder")
    }
}

struct SelectiveRemoteProfileFolderNode: Identifiable, Equatable {
    let path: String
    let profiles: [ConnectionProfile]
    let children: [SelectiveRemoteProfileFolderNode]

    var id: String { path }
    var name: String { SelectiveRemoteHostFolderPath.displayName(path) }

    static func roots(from sections: [ProfileGroupSection]) -> [Self] {
        let entries = sections.flatMap { section in
            section.profiles.map { (SelectiveRemoteHostFolderPath.normalize($0.group), $0) }
        }
        return children(parent: "", entries: entries)
    }

    private static func children(
        parent: String,
        entries: [(String, ConnectionProfile)]
    ) -> [Self] {
        let directProfiles = entries.filter { $0.0 == parent }.map(\.1)
        var childNames = Set<String>()
        let prefix = parent.isEmpty ? "" : "\(parent)/"
        for (path, _) in entries where path.hasPrefix(prefix) && path != parent {
            let remainder = path.dropFirst(prefix.count)
            if let component = remainder.split(separator: "/").first {
                childNames.insert(String(component))
            }
        }
        var result = childNames.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }.map { component in
            let path = parent.isEmpty ? component : "\(parent)/\(component)"
            let nested = entries.filter { $0.0 == path || $0.0.hasPrefix("\(path)/") }
            return Self(
                path: path,
                profiles: nested.filter { $0.0 == path }.map(\.1),
                children: children(parent: path, entries: nested)
            )
        }
        if parent.isEmpty, !directProfiles.isEmpty {
            result.insert(Self(path: "", profiles: directProfiles, children: []), at: 0)
        }
        return result
    }
}

struct SelectiveRemoteProfileOutlineItem: Identifiable, Equatable {
    enum Kind: Equatable {
        case folder(path: String, name: String)
        case profile(ConnectionProfile)
    }

    let id: String
    let kind: Kind
    let children: [SelectiveRemoteProfileOutlineItem]?

    static func roots(from folders: [SelectiveRemoteProfileFolderNode]) -> [Self] {
        folders.map(makeFolder)
    }

    private static func makeFolder(_ folder: SelectiveRemoteProfileFolderNode) -> Self {
        let nested = folder.children.map(makeFolder)
            + folder.profiles.map {
                Self(id: "profile:\($0.id.uuidString)", kind: .profile($0), children: nil)
            }
        return Self(
            id: "folder:\(folder.path)",
            kind: .folder(path: folder.path, name: folder.name),
            children: nested
        )
    }
}

struct SelectiveRemoteTeamHostOutlineItem: Identifiable, Equatable {
    enum Kind: Equatable {
        case folder(path: String, name: String)
        case host(SelectiveRemoteTeamHost)
    }

    let id: String
    let kind: Kind
    let children: [SelectiveRemoteTeamHostOutlineItem]?

    static func roots(teamID: UUID, hosts: [SelectiveRemoteTeamHost]) -> [Self] {
        let entries = hosts.map {
            (SelectiveRemoteHostFolderPath.normalize($0.profile.group), $0)
        }
        return children(teamID: teamID, parent: "", entries: entries)
    }

    private static func children(
        teamID: UUID,
        parent: String,
        entries: [(String, SelectiveRemoteTeamHost)]
    ) -> [Self] {
        let prefix = parent.isEmpty ? "" : "\(parent)/"
        var childNames = Set<String>()
        for (path, _) in entries where path.hasPrefix(prefix) && path != parent {
            if let component = path.dropFirst(prefix.count).split(separator: "/").first {
                childNames.insert(String(component))
            }
        }
        var result = childNames.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }.map { component in
            let path = parent.isEmpty ? component : "\(parent)/\(component)"
            let nested = entries.filter { $0.0 == path || $0.0.hasPrefix("\(path)/") }
            let descendants = children(teamID: teamID, parent: path, entries: nested)
                + hostItems(teamID: teamID, path: path, entries: nested)
            return Self(
                id: "team-folder:\(teamID.uuidString):\(path)",
                kind: .folder(path: path, name: SelectiveRemoteHostFolderPath.displayName(path)),
                children: descendants
            )
        }
        if parent.isEmpty {
            let ungrouped = hostItems(teamID: teamID, path: "", entries: entries)
            if !ungrouped.isEmpty {
                result.insert(
                    Self(
                        id: "team-folder:\(teamID.uuidString):",
                        kind: .folder(
                            path: "",
                            name: UpdateLocalization.text(ru: "Без папки", en: "No Folder")
                        ),
                        children: ungrouped
                    ),
                    at: 0
                )
            }
        }
        return result
    }

    private static func hostItems(
        teamID: UUID,
        path: String,
        entries: [(String, SelectiveRemoteTeamHost)]
    ) -> [Self] {
        entries.filter { $0.0 == path }
            .map(\.1)
            .sorted { lhs, rhs in
                if lhs.profile.sortIndex != rhs.profile.sortIndex {
                    return lhs.profile.sortIndex < rhs.profile.sortIndex
                }
                return lhs.profile.friendlyName.localizedCaseInsensitiveCompare(
                    rhs.profile.friendlyName
                ) == .orderedAscending
            }
            .map {
                Self(
                    id: "team-host:\(teamID.uuidString):\($0.id.uuidString)",
                    kind: .host($0),
                    children: nil
                )
            }
    }
}
