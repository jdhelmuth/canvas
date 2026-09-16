import Foundation
import XCTest
@testable import Canvas

final class SettingsReliabilityTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }

    private func date(_ day: Int, hour: Int, month: Int = 9) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
    }

    func testDateRangeIncludesBothEntireBoundaryDays() {
        let start = date(10, hour: 14)
        let end = date(15, hour: 14)
        for item in [date(10, hour: 0), date(10, hour: 8), date(15, hour: 23)] {
            XCTAssertTrue(CaptureDateRange.contains(item, from: start, through: end, calendar: calendar))
        }
        XCTAssertFalse(CaptureDateRange.contains(date(9, hour: 23), from: start, through: end, calendar: calendar))
        XCTAssertFalse(CaptureDateRange.contains(date(16, hour: 0), from: start, through: end, calendar: calendar))
    }

    func testDateRangeUsesCalendarDayAcrossDaylightSavingChanges() {
        for (month, day) in [(3, 8), (11, 1)] {
            let selected = date(day, hour: 12, month: month)
            let start = calendar.startOfDay(for: selected)
            let next = calendar.date(byAdding: .day, value: 1, to: start)!
            XCTAssertTrue(CaptureDateRange.contains(next.addingTimeInterval(-1), from: selected, through: selected, calendar: calendar))
            XCTAssertFalse(CaptureDateRange.contains(next, from: selected, through: selected, calendar: calendar))
        }
    }

    func testDateRangeNormalizesReversedDaysAndExcludesUnknownDatesOnlyWhenActive() {
        XCTAssertTrue(CaptureDateRange.contains(date(12, hour: 12), from: date(15, hour: 12), through: date(10, hour: 12), calendar: calendar))
        XCTAssertTrue(CaptureDateRange.contains(nil, from: nil, through: nil, calendar: calendar))
        XCTAssertFalse(CaptureDateRange.contains(nil, from: date(10, hour: 12), through: nil, calendar: calendar))
    }

    func testMediaFilterUsesInclusiveCalendarDays() {
        var filters = CanvasFilters()
        filters.endDate = date(15, hour: 0)
        let photo = MediaDescriptor(id: "test", kind: .photo, creationDate: date(15, hour: 23), modificationDate: nil, filename: "test.jpg", isFavorite: false, pixelWidth: 10, pixelHeight: 10, albumTitles: [])
        XCTAssertTrue(filters.accepts(photo, calendar: calendar))
    }

    @MainActor
    func testCorruptSettingsRemainRecoverableAfterEditingDefaultsAndRelaunch() throws {
        let suite = "CanvasTests.corrupt.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let original = Data("{broken settings".utf8)
        defaults.set(original, forKey: "canvas.settings.v1")
        let store = SettingsStore(defaults: defaults)
        XCTAssertNotNil(store.recoveryMessage)
        XCTAssertEqual(defaults.data(forKey: SettingsStore.recoveryDataKey), original)
        store.update { $0.photoDuration = 47 }
        let restored = SettingsStore(defaults: defaults)
        XCTAssertEqual(restored.settings.photoDuration, 47)
        XCTAssertEqual(defaults.data(forKey: SettingsStore.recoveryDataKey), original)
        XCTAssertNotNil(restored.recoveryMessage)
        restored.dismissRecoveryNotice()
        XCTAssertNil(SettingsStore(defaults: defaults).recoveryMessage)
        XCTAssertEqual(defaults.data(forKey: SettingsStore.recoveryDataKey), original)
    }

    @MainActor
    func testNewerSettingsSchemaIsNeverOverwritten() throws {
        let suite = "CanvasTests.newer.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var original = CanvasSettings()
        original.photoDuration = 81
        let data = try JSONEncoder().encode(original)
        defaults.set(data, forKey: "canvas.settings.v1")
        defaults.set(999, forKey: "canvas.settings.schema")
        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.settings.photoDuration, 81)
        XCTAssertNotNil(store.recoveryMessage)
        store.update { $0.photoDuration = 7 }
        XCTAssertEqual(defaults.data(forKey: "canvas.settings.v1"), data)
        XCTAssertEqual(defaults.integer(forKey: "canvas.settings.schema"), 999)
    }

    func testSameNamedAudioImportsKeepBothFilesInSelectionOrder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("store")
        let first = root.appendingPathComponent("one/music.mp3")
        let second = root.appendingPathComponent("two/music.mp3")
        for url in [first, second] {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        try Data("one".utf8).write(to: first)
        try Data("two".utf8).write(to: second)
        let store = CanvasAudioFileStore(directory: directory, validate: { _ in })
        let imported = store.importFiles([first, second])
        XCTAssertTrue(imported.failedFilenames.isEmpty)
        XCTAssertEqual(imported.references.count, 2)
        XCTAssertNotEqual(imported.references[0], imported.references[1])
        XCTAssertNil(imported.references[0].scheme)
        for (reference, expected) in zip(imported.references, ["one", "two"]) {
            XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(reference.lastPathComponent)), Data(expected.utf8))
        }
    }

    func testFailedAudioCopyOrValidationPreservesExistingTracksAndCleansStaging() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("store")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let existing = directory.appendingPathComponent("music.mp3")
        try Data("saved".utf8).write(to: existing)
        let invalid = root.appendingPathComponent("music.mp3")
        try Data("invalid audio".utf8).write(to: invalid)
        let store = CanvasAudioFileStore(directory: directory)
        let imported = store.importFiles([invalid, root.appendingPathComponent("missing/music.mp3")])
        XCTAssertEqual(imported.failedFilenames.count, 2)
        XCTAssertTrue(imported.references.isEmpty)
        XCTAssertEqual(try Data(contentsOf: existing), Data("saved".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["music.mp3"])
    }

    func testAudioReferencesRebaseLegacyAndRelativePathsIntoCurrentContainer() {
        let legacy = URL(fileURLWithPath: "/old/container/Library/Application Support/Canvas Audio/music.mp3")
        let relative = URL(string: "music.mp3")!
        XCTAssertEqual(CanvasAudioFileStore.playbackURL(for: legacy), CanvasAudioFileStore.playbackURL(for: relative))
        XCTAssertEqual(CanvasAudioFileStore.playbackURL(for: relative).deletingLastPathComponent(), CanvasAudioFileStore.defaultDirectory)
    }

    func testLongValidAudioFilenameUsesBoundedInternalName() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent(String(repeating: "a", count: 220) + ".mp3")
        try Data("test".utf8).write(to: source)
        let store = CanvasAudioFileStore(directory: root.appendingPathComponent("store"), validate: { _ in })
        let result = store.importFiles([source])
        XCTAssertTrue(result.failedFilenames.isEmpty)
        XCTAssertEqual(result.references.count, 1)
        XCTAssertLessThan(result.references[0].lastPathComponent.utf8.count, 64)
    }
}
