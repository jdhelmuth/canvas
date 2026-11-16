import XCTest
@testable import Canvas

final class AlbumMembershipSnapshotTests: XCTestCase {
    private func album(_ id: String = "album") -> AlbumReference {
        AlbumReference(id: id, title: "Synthetic", subtype: 2, estimatedCount: 0, isSmart: false, isShared: false)
    }
    func testMissingEmptyAndPartialReadsKeepMembersUntilRecovery() {
        var snapshot = AlbumMembershipSnapshot()
        let ref = album()
        snapshot.observe(reference: ref, ids: ["a", "b"], authoritative: false, generation: 1)
        for (index, ids) in ([nil, [], ["b", "c"]] as [[String]?]).enumerated() {
            snapshot.observe(reference: ref, ids: ids, authoritative: false, generation: UInt64(index + 2))
            XCTAssertTrue(Set(snapshot.records[ref.id]!.assetIDs).isSuperset(of: ["a", "b"]))
            XCTAssertTrue(snapshot.records[ref.id]!.pending)
        }
        snapshot.observe(reference: ref, ids: ["a", "b", "c", "c"], authoritative: false, generation: 5)
        XCTAssertEqual(snapshot.records[ref.id]?.assetIDs, ["a", "b", "c"])
        XCTAssertFalse(snapshot.records[ref.id]!.pending)
    }
    func testIncrementalRemovalAndDeletionAreAuthoritative() {
        var snapshot = AlbumMembershipSnapshot()
        let ref = album()
        snapshot.observe(reference: ref, ids: ["a", "b"], authoritative: false, generation: 1)
        snapshot.observe(reference: ref, ids: [], authoritative: true, generation: 2)
        XCTAssertEqual(snapshot.records[ref.id]?.assetIDs, [])
        XCTAssertFalse(snapshot.records[ref.id]!.pending)
        snapshot.confirmDeleted(ref, generation: 3)
        snapshot.observe(reference: ref, ids: ["a"], authoritative: false, generation: 4)
        XCTAssertTrue(snapshot.records[ref.id]!.deleted)
        XCTAssertEqual(snapshot.records[ref.id]?.assetIDs, [])
    }
    func testOlderSnapshotsCannotUndoNewMembership() {
        var snapshot = AlbumMembershipSnapshot()
        let ref = album()
        snapshot.observe(reference: ref, ids: ["a", "b"], authoritative: true, generation: 3)
        snapshot.observe(reference: ref, ids: ["a"], authoritative: true, generation: 2)
        snapshot.confirmDeleted(ref, generation: 1)
        XCTAssertEqual(snapshot.records[ref.id]?.assetIDs, ["a", "b"])
        XCTAssertFalse(snapshot.records[ref.id]!.deleted)
    }
    func testRepeatedPartialReadsCannotConfirmRemovalByTimeout() {
        var snapshot = AlbumMembershipSnapshot()
        let ref = album()
        snapshot.observe(reference: ref, ids: ["a", "b"], authoritative: false, generation: 1)
        for generation in 2...50 {
            snapshot.observe(reference: ref, ids: ["a"], authoritative: false, generation: UInt64(generation))
            XCTAssertEqual(snapshot.records[ref.id]?.assetIDs, ["a", "b"])
            XCTAssertTrue(snapshot.records[ref.id]!.pending)
        }
        snapshot.observe(reference: ref, ids: ["a"], authoritative: true, generation: 51)
        XCTAssertEqual(snapshot.records[ref.id]?.assetIDs, ["a"])
        XCTAssertFalse(snapshot.records[ref.id]!.pending)
    }
    func testRestartRetainsOverlappingThousandPhotoPoolsWithoutDuplicates() throws {
        var snapshot = AlbumMembershipSnapshot()
        let first = album("first"), second = album("second")
        snapshot.observe(reference: first, ids: (0..<1200).map(String.init), authoritative: false, generation: 1)
        snapshot.observe(reference: second, ids: (600..<1800).map(String.init), authoritative: false, generation: 2)
        var restored = try JSONDecoder().decode(AlbumMembershipSnapshot.self, from: JSONEncoder().encode(snapshot))
        restored.beginSession()
        restored.observe(reference: first, ids: nil, authoritative: false, generation: 1)
        restored.observe(reference: second, ids: (600..<1804).map(String.init), authoritative: false, generation: 2)
        XCTAssertEqual(Set(restored.records.values.flatMap(\.assetIDs)).count, 1804)
        XCTAssertTrue(restored.records[first.id]!.pending)
        XCTAssertFalse(restored.records[second.id]!.pending)
    }
    func testIdentityMigrationRequiresExplicitProvenIDAndPreservesMembers() {
        var snapshot = AlbumMembershipSnapshot()
        snapshot.observe(reference: album("old"), ids: ["a", "b"], authoritative: true, generation: 1)
        snapshot.observe(reference: album("new"), ids: ["b", "c"], authoritative: false, generation: 2)
        snapshot.reidentify(from: "old", to: album("new"))
        XCTAssertNil(snapshot.records["old"])
        XCTAssertEqual(snapshot.records["new"]?.assetIDs, ["b", "c", "a"])
        XCTAssertTrue(snapshot.records["new"]!.pending)
        snapshot.removeAssets(["a"])
        XCTAssertEqual(snapshot.records["new"]?.assetIDs, ["b", "c"])
    }
    func testOverlappingPoolsAdditionsAndRestartFinishCycleBeforeAnyRepeat() throws {
        var snapshot = AlbumMembershipSnapshot()
        let first = album("first"), second = album("second")
        snapshot.observe(reference: first, ids: (0..<1200).map(String.init), authoritative: false, generation: 1)
        snapshot.observe(reference: second, ids: (600..<1800).map(String.init), authoritative: false, generation: 2)
        func items(_ snapshot: AlbumMembershipSnapshot) -> [CanvasMediaItem] {
            Set(snapshot.records.values.flatMap(\.assetIDs)).sorted().map {
                CanvasMediaItem(id: $0, source: .applePhotos, kind: .photo, creationDate: nil, filename: $0,
                    isFavorite: false, pixelWidth: 100, pixelHeight: 100, albumTitle: "Synthetic",
                    appleAsset: nil, localURL: nil, contentHash: nil)
            }
        }
        var cycle = ShuffleCycle()
        cycle.reconcile(QueueBuilder.build(items(snapshot), mode: .shuffle, repeatEnabled: true, shuffleSeed: 7))
        let firstBatch = Array(cycle.pendingIDs().prefix(900))
        cycle.recordDisplayed(firstBatch)
        let failedDownload = try XCTUnwrap(cycle.pendingIDs().first)
        snapshot.observe(reference: first, ids: nil, authoritative: false, generation: 3)
        snapshot.observe(reference: second, ids: (600..<1805).map(String.init), authoritative: false, generation: 4)
        cycle = try JSONDecoder().decode(ShuffleCycle.self, from: JSONEncoder().encode(cycle))
        cycle.reconcile(items(snapshot))
        XCTAssertTrue(cycle.pendingIDs().contains(failedDownload), "Failed downloads remain unconsumed")
        var displayed = Set(firstBatch)
        for id in cycle.pendingIDs() {
            XCTAssertTrue(displayed.insert(id).inserted, "No repeats before full coverage")
            cycle.recordDisplayed([id])
        }
        XCTAssertEqual(displayed.count, 1805)
        XCTAssertTrue(cycle.pendingIDs().isEmpty)
        let last = cycle.lastGroupIDs
        cycle.beginNextCycle(QueueBuilder.buildNextCycle(items(snapshot), mode: .shuffle, previousIDs: last, shuffleSeed: 8))
        XCTAssertFalse(last.contains(try XCTUnwrap(cycle.pendingIDs().first)))
    }

}
