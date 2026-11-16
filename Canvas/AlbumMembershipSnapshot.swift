import Foundation

/// Metadata only: no image bytes, Photos writes, or name-based identity repair.
/// Samples may add members immediately. Missing members require explicit
/// Photos change evidence; elapsed time cannot prove an iCloud read complete.
struct AlbumMembershipSnapshot: Codable, Equatable {
    struct Record: Codable, Equatable {
        var reference: AlbumReference
        var assetIDs: [String]
        var pending = false
        var deleted = false
    }
    private(set) var records: [String: Record] = [:]
    private var generations: [String: UInt64] = [:]
    private enum CodingKeys: String, CodingKey { case records }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.records == rhs.records }

    mutating func beginSession() {
        for key in Array(records.keys) {
            let pending = records[key]?.deleted == false
            records[key]?.pending = pending
        }
        generations.removeAll()
    }

    mutating func reidentify(from oldID: String, to reference: AlbumReference) {
        guard oldID != reference.id, let old = records.removeValue(forKey: oldID), !old.deleted else { return }
        if var current = records[reference.id] {
            if !current.deleted {
                let known = Set(current.assetIDs)
                current.assetIDs += old.assetIDs.filter { !known.contains($0) }
                current.reference = reference; current.pending = true
                records[reference.id] = current
            }
        } else {
            var moved = old; moved.reference = reference; moved.pending = true
            records[reference.id] = moved
        }
        generations.removeValue(forKey: oldID)
    }

    mutating func observe(reference: AlbumReference, ids: [String]?, authoritative: Bool,
                         generation: UInt64) {
        let key = reference.id
        guard generation >= generations[key, default: 0] else { return }
        generations[key] = generation
        guard let ids else {
            records[key]?.pending = true
            return
        }
        var seen = Set<String>()
        let unique = ids.filter { seen.insert($0).inserted }
        let previous = records[key]
        guard previous?.deleted != true else { return }
        if authoritative || previous == nil || Set(previous!.assetIDs).isSubset(of: seen) {
            records[key] = Record(reference: reference, assetIDs: unique)
            return
        }
        // Repeated identical partial reads can outlast any timeout during
        // iCloud propagation. Only change evidence confirms member removals.
        let old = previous!.assetIDs
        let oldSet = Set(old)
        records[key] = Record(reference: reference, assetIDs: old + unique.filter { !oldSet.contains($0) }, pending: true)
    }

    mutating func confirmDeleted(_ reference: AlbumReference, generation: UInt64) {
        guard generation >= generations[reference.id, default: 0] else { return }
        generations[reference.id] = generation
        records[reference.id] = Record(reference: reference, assetIDs: [], deleted: true)
    }

    mutating func removeAssets(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        for key in records.keys { records[key]?.assetIDs.removeAll { ids.contains($0) } }
    }

}
