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

    /// Refreshes the media backing a queue without treating a provider
    /// notification as a new slideshow session. Existing identifiers keep
    /// their playback order; newly discovered media is appended in the
    /// configured order. A settings-driven rebuild should continue to call
    /// `build` so an intentional shuffle or filter change can take effect.
    static func refresh(
        _ existingQueue: [CanvasMediaItem],
        with assets: [CanvasMediaItem],
        mode: QueueMode,
        repeatEnabled: Bool,
        previousIDs: [String] = [],
        recentAvoidance: Int = 0,
        shuffleSeed: Int = 0
    ) -> [CanvasMediaItem] {
        guard !assets.isEmpty else { return [] }
        guard !existingQueue.isEmpty else {
            return build(
                assets,
                mode: mode,
                repeatEnabled: repeatEnabled,
                previousIDs: previousIDs,
                recentAvoidance: recentAvoidance,
                shuffleSeed: shuffleSeed
            )
        }

        var latestByID: [String: CanvasMediaItem] = [:]
        latestByID.reserveCapacity(assets.count)
        for asset in assets {
            latestByID[asset.id] = asset
        }

        let surviving = existingQueue.compactMap { latestByID[$0.id] }
        guard !surviving.isEmpty else {
            return build(
                assets,
                mode: mode,
                repeatEnabled: repeatEnabled,
                previousIDs: previousIDs,
                recentAvoidance: recentAvoidance,
                shuffleSeed: shuffleSeed
            )
        }

        let survivingIDs = Set(surviving.map(\.id))
        let additions = assets.filter { !survivingIDs.contains($0.id) }
        guard !additions.isEmpty else { return surviving }

        return surviving + build(
            additions,
            mode: mode,
            repeatEnabled: true,
            previousIDs: previousIDs,
            recentAvoidance: recentAvoidance,
            shuffleSeed: shuffleSeed
        )
    }

    /// Shuffle the complete selected-media pool while preventing a large
    /// album from crowding out smaller selected albums. Each library bucket
    /// contributes randomized items in small orientation runs, and the run
    /// order changes every round. Keeping runs short makes a same-orientation
    /// pair available without putting the entire slideshow into one portrait
    /// or landscape band.
    private static func shuffledAcrossLibraries(
        _ assets: [CanvasMediaItem],
        using generator: inout SeededGenerator
    ) -> [CanvasMediaItem] {
        let bands = Dictionary(grouping: assets, by: orientationKey)
        var bandKeys = Array(bands.keys)
        var shuffledBands: [String: [CanvasMediaItem]] = [:]
        var positions: [String: Int] = [:]
        for key in bandKeys {
            guard let band = bands[key] else { continue }
            shuffledBands[key] = shuffledLibraryBuckets(band, using: &generator)
            positions[key] = 0
        }

        var output: [CanvasMediaItem] = []
        output.reserveCapacity(assets.count)
        while !bandKeys.isEmpty {
            bandKeys.shuffle(using: &generator)
            var nextKeys: [String] = []
            nextKeys.reserveCapacity(bandKeys.count)
            for key in bandKeys {
                guard let band = shuffledBands[key], let start = positions[key], start < band.count else { continue }
                let end = min(start + 2, band.count)
                output.append(contentsOf: band[start..<end])
                positions[key] = end
                if end < band.count { nextKeys.append(key) }
            }
            bandKeys = nextKeys
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
