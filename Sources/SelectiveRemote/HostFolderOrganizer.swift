import Foundation

enum SelectiveRemoteHostOrder {
    static func move(
        profiles: [ConnectionProfile], profileID: UUID,
        toFolder rawFolder: String, before targetID: UUID? = nil
    ) -> [ConnectionProfile]? {
        guard let source = profiles.first(where: { $0.id == profileID }) else { return nil }
        let oldFolder = SelectiveRemoteHostFolderPath.normalize(source.group)
        let folder = SelectiveRemoteHostFolderPath.normalize(rawFolder)
        if targetID == profileID && oldFolder == folder { return nil }
        if let targetID,
           !profiles.contains(where: {
               $0.id == targetID && SelectiveRemoteHostFolderPath.normalize($0.group) == folder
           }) { return nil }
        var result = profiles
        guard let sourceIndex = result.firstIndex(where: { $0.id == profileID }) else { return nil }
        result[sourceIndex].group = folder
        if oldFolder != folder {
            let depth = SelectiveRemoteHostFolderPath.components(folder).count
            result[sourceIndex].folderOrderPath = Array(
                (profiles.first {
                    $0.id != profileID && ($0.group == folder || $0.group.hasPrefix(folder + "/"))
                }?.folderOrderPath ?? []).prefix(depth)
            )
        }
        var destination = result.filter {
            $0.id != profileID && SelectiveRemoteHostFolderPath.normalize($0.group) == folder
        }.sorted { lhs, rhs in
            if lhs.sortIndex != rhs.sortIndex { return lhs.sortIndex < rhs.sortIndex }
            return lhs.friendlyName.localizedCaseInsensitiveCompare(rhs.friendlyName)
                == .orderedAscending
        }.map(\.id)
        let insertion = targetID.flatMap { destination.firstIndex(of: $0) }
            ?? destination.endIndex
        destination.insert(profileID, at: insertion)
        for (order, id) in destination.enumerated() {
            if let index = result.firstIndex(where: { $0.id == id }) {
                result[index].sortIndex = order
            }
        }
        if oldFolder != folder {
            let oldIDs = result.filter {
                SelectiveRemoteHostFolderPath.normalize($0.group) == oldFolder
            }.sorted { $0.sortIndex < $1.sortIndex }.map(\.id)
            for (order, id) in oldIDs.enumerated() {
                if let index = result.firstIndex(where: { $0.id == id }) {
                    result[index].sortIndex = order
                }
            }
        }
        return result == profiles ? nil : result
    }
}

enum SelectiveRemoteHostFolderOrganizer {
    enum Error: Swift.Error {
        case missingFolder
        case invalidDestination
        case duplicateFolder
    }

    static func folderComesBefore(
        _ lhs: String, _ rhs: String, profiles: [ConnectionProfile]
    ) -> Bool {
        func rank(_ path: String) -> [Int]? {
            profiles.filter { $0.group == path || $0.group.hasPrefix(path + "/") }
                .map(\.folderOrderPath)
                .filter { !$0.isEmpty }
                .min { $0.lexicographicallyPrecedes($1) }
        }
        let left = rank(lhs)
        let right = rank(rhs)
        if let left, let right, left != right {
            return left.lexicographicallyPrecedes(right)
        }
        return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
    }

    static func visibleFolderPaths(profiles: [ConnectionProfile]) -> [String] {
        var paths = Set(profiles.flatMap { folderPrefixes($0.group) })
        if profiles.contains(where: { $0.group.isEmpty }) { paths.insert("") }
        return paths.sorted { folderComesBefore($0, $1, profiles: profiles) }
    }

    static func move(
        profiles: [ConnectionProfile],
        folder rawFolder: String,
        toParent rawParent: String,
        before rawTarget: String? = nil
    ) throws -> [ConnectionProfile] {
        let folder = SelectiveRemoteHostFolderPath.normalize(rawFolder)
        let parent = SelectiveRemoteHostFolderPath.normalize(rawParent)
        let target = rawTarget.map(SelectiveRemoteHostFolderPath.normalize)
        let allPaths = Set(profiles.flatMap { folderPrefixes($0.group) })
        guard !folder.isEmpty, allPaths.contains(folder) else { throw Error.missingFolder }
        guard parent.isEmpty || allPaths.contains(parent),
              parent != folder, !parent.hasPrefix(folder + "/")
        else { throw Error.invalidDestination }
        let name = SelectiveRemoteHostFolderPath.displayName(folder)
        let destination = parent.isEmpty ? name : parent + "/" + name
        guard destination == folder || !allPaths.contains(destination) else {
            throw Error.duplicateFolder
        }
        guard SelectiveRemoteHostFolderPath.normalize(destination) == destination else {
            throw Error.invalidDestination
        }

        let oldParent = String(folder.dropLast(name.count)).dropLast().description
        if destination == folder && target == folder { return profiles }
        let ordered = orderedChildren(profiles: profiles, paths: allPaths)
        var nextOrders: [String: [String]] = [:]
        for (path, children) in ordered {
            let newPath = replacingPrefix(path, from: folder, to: destination)
            nextOrders[newPath] = children.map {
                replacingPrefix($0, from: folder, to: destination)
            }
        }
        nextOrders[oldParent]?.removeAll { $0 == folder }
        var siblings = nextOrders[parent] ?? []
        siblings.removeAll { $0 == destination }
        let index = target.flatMap { siblings.firstIndex(of: $0) } ?? siblings.endIndex
        siblings.insert(destination, at: index)
        nextOrders[parent] = siblings

        return profiles.map { input in
            var result = input
            result.group = replacingPrefix(
                SelectiveRemoteHostFolderPath.normalize(input.group),
                from: folder, to: destination
            )
            let prefixes = folderPrefixes(result.group)
            result.folderOrderPath = prefixes.map { path in
                let parent = path.split(separator: "/").dropLast().joined(separator: "/")
                return nextOrders[parent]?.firstIndex(of: path) ?? 0
            }
            return result
        }
    }

    private static func folderPrefixes(_ rawPath: String) -> [String] {
        let components = SelectiveRemoteHostFolderPath.components(rawPath)
        return components.indices.map { components[0 ... $0].joined(separator: "/") }
    }

    private static func replacingPrefix(
        _ path: String, from source: String, to destination: String
    ) -> String {
        if path == source { return destination }
        if path.hasPrefix(source + "/") { return destination + path.dropFirst(source.count) }
        return path
    }

    private static func orderedChildren(
        profiles: [ConnectionProfile], paths: Set<String>
    ) -> [String: [String]] {
        var children: [String: [String]] = [:]
        for path in paths {
            let parent = path.split(separator: "/").dropLast().joined(separator: "/")
            children[parent, default: []].append(path)
        }
        for (parent, values) in children {
            let depth = SelectiveRemoteHostFolderPath.components(parent).count
            children[parent] = values.sorted { lhs, rhs in
                let lhsRank = profiles.filter { $0.group == lhs || $0.group.hasPrefix(lhs + "/") }
                    .compactMap { $0.folderOrderPath.indices.contains(depth) ? $0.folderOrderPath[depth] : nil }
                    .min()
                let rhsRank = profiles.filter { $0.group == rhs || $0.group.hasPrefix(rhs + "/") }
                    .compactMap { $0.folderOrderPath.indices.contains(depth) ? $0.folderOrderPath[depth] : nil }
                    .min()
                if let lhsRank, let rhsRank, lhsRank != rhsRank { return lhsRank < rhsRank }
                return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
            }
        }
        return children
    }
}
