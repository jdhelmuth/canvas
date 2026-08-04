import Foundation

struct QueueBuilder {
    static func build(_ assets: [CanvasMediaItem], mode: QueueMode, repeatEnabled: Bool, previousIDs: [String] = [], recentAvoidance: Int = 0, shuffleSeed: Int = 0) -> [CanvasMediaItem] {
        guard !assets.isEmpty else { return [] }
        var output: [CanvasMediaItem]
        switch mode {
        case .shuffle:
            var generator = SeededGenerator(seed: UInt64(bitPattern: Int64(shuffleSeed)) ^ UInt64(assets.count))
            output = shuffledAcrossLibraries(assets, using: &generator)
        case .albumOrder: output = assets
        case .oldestFirst: output = assets.sorted { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }
        case .newestFirst: output = assets.sorted { ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast) }
        case .filename: output = assets.sorted { $0.filename.localizedCaseInsensitiveCompare($1.filename) == .orderedAscending }
        case .favoritesFirst: output = assets.sorted { $0.isFavorite && !$1.isFavorite }
        }
        if recentAvoidance > 0 && output.count > recentAvoidance {
            let recent = Set(previousIDs.suffix(recentAvoidance))
            let preferred = output.filter { !recent.contains($0.id) }
            let held = output.filter { recent.contains($0.id) }
            output = preferred + held
        }
        return repeatEnabled ? output : Array(output.prefix(output.count))
    }

    /// Shuffle the complete selected-media pool while preventing a large
    /// album from crowding out smaller selected albums. Each library bucket
    /// contributes one randomized item per round, and the bucket order is
    /// randomized again for every round. This keeps the queue genuinely
    /// broad without dropping any eligible media or changing group layout
    /// semantics (groups are still resolved from adjacent queue items).
    private static func shuffledAcrossLibraries(
        _ assets: [CanvasMediaItem],
        using generator: inout SeededGenerator
    ) -> [CanvasMediaItem] {
        // Keep orientation bands together. Automatic pairing advances by
        // adjacent queue groups; mixing portrait and landscape items between
        // those bands would make a later compatible companion skip the item
        // in between. Each band is still balanced across selected libraries.
        let bands = Dictionary(grouping: assets, by: orientationKey)
        var bandKeys = Array(bands.keys)
        bandKeys.shuffle(using: &generator)

        var output: [CanvasMediaItem] = []
        output.reserveCapacity(assets.count)
        for bandKey in bandKeys {
            guard let band = bands[bandKey] else { continue }
            output.append(contentsOf: shuffledLibraryBuckets(band, using: &generator))
        }
        return output
    }

    private static func shuffledLibraryBuckets(
        _ assets: [CanvasMediaItem],
        using generator: inout SeededGenerator
    ) -> [CanvasMediaItem] {
        var buckets = Dictionary(grouping: assets, by: libraryKey)
        var activeKeys = Array(buckets.keys)
        for key in activeKeys {
            buckets[key]?.shuffle(using: &generator)
        }

        var output: [CanvasMediaItem] = []
        output.reserveCapacity(assets.count)
        while !activeKeys.isEmpty {
            activeKeys.shuffle(using: &generator)
            var nextKeys: [String] = []
            nextKeys.reserveCapacity(activeKeys.count)
            for key in activeKeys {
                guard var bucket = buckets[key], !bucket.isEmpty else { continue }
                output.append(bucket.removeLast())
                if !bucket.isEmpty { nextKeys.append(key) }
                buckets[key] = bucket
            }
            activeKeys = nextKeys
        }
        return output
    }

    private static func orientationKey(for asset: CanvasMediaItem) -> String {
        guard asset.pixelWidth > 0, asset.pixelHeight > 0 else { return "unknown" }
        return asset.pixelHeight > asset.pixelWidth ? "portrait" : "landscape"
    }

    private static func libraryKey(for asset: CanvasMediaItem) -> String {
        "\(asset.source.rawValue)|\(asset.libraryID ?? asset.albumTitle)"
    }
}

@MainActor
final class QueueService: ObservableObject {
    @Published private(set) var assets: [CanvasMediaItem] = []
    @Published private(set) var index = 0
    @Published private(set) var exhausted = false

    func rebuild(assets: [CanvasMediaItem], settings: CanvasSettings, previousIDs: [String] = []) {
        self.assets = QueueBuilder.build(assets, mode: settings.queueMode, repeatEnabled: settings.repeatEnabled, previousIDs: previousIDs, recentAvoidance: settings.recentAvoidance, shuffleSeed: Int.random(in: Int.min...Int.max))
        index = min(index, max(0, self.assets.count - 1))
        exhausted = self.assets.isEmpty
    }

    var current: CanvasMediaItem? { assets.indices.contains(index) ? assets[index] : nil }
    func next(repeatEnabled: Bool, reshuffle: Bool = false, settings: CanvasSettings? = nil) {
        guard !assets.isEmpty else { return }
        if index + 1 < assets.count { index += 1; return }
        guard repeatEnabled else { exhausted = true; return }
        if reshuffle, let settings { assets = QueueBuilder.build(assets, mode: settings.queueMode, repeatEnabled: true, shuffleSeed: Int.random(in: Int.min...Int.max)); index = 0 }
        else { index = 0 }
    }
    func previous() { guard !assets.isEmpty else { return }; index = index > 0 ? index - 1 : assets.count - 1 }
    func jump(to newIndex: Int) { guard assets.indices.contains(newIndex) else { return }; index = newIndex }
}

struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0xA5A5A5A5 : seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
