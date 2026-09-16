import AVFoundation
import Foundation

struct CanvasAudioImportResult: Sendable {
    let references: [URL]
    let failedFilenames: [String]
}

/// Files have unique internal names and are committed only after a complete,
/// playable copy exists. Saved references survive app-container relocation.
struct CanvasAudioFileStore {
    let directory: URL
    private let validate: (URL) throws -> Void

    init(directory: URL = Self.defaultDirectory, validate: @escaping (URL) throws -> Void = { url in
        _ = try AVAudioPlayer(contentsOf: url)
    }) {
        self.directory = directory
        self.validate = validate
    }

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Canvas Audio", isDirectory: true)
    }

    static func playbackURL(for storedURL: URL) -> URL {
        // Older versions saved absolute container URLs. The basename still
        // identifies their file after an upgrade/restore relocates the container.
        defaultDirectory.appendingPathComponent(storedURL.lastPathComponent)
    }

    func importFiles(_ urls: [URL]) -> CanvasAudioImportResult {
        let files = FileManager.default
        var references: [URL] = []
        var failed: [String] = []
        for source in urls {
            let scoped = source.startAccessingSecurityScopedResource()
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }
            let ext = source.pathExtension
            let safeExtension = ext.count <= 16 && ext.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) }
                ? ext : ""
            let basename = UUID().uuidString + (safeExtension.isEmpty ? "" : "." + safeExtension)
            let destination = directory.appendingPathComponent(basename)
            let staged = directory.appendingPathComponent(".import-" + basename)
            defer { try? files.removeItem(at: staged) }
            do {
                try files.createDirectory(at: directory, withIntermediateDirectories: true)
                try files.copyItem(at: source, to: staged)
                try validate(staged)
                try files.moveItem(at: staged, to: destination)
                if let reference = URL(string: basename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? basename) {
                    references.append(reference)
                }
            } catch {
                failed.append(source.lastPathComponent)
            }
        }
        return CanvasAudioImportResult(references: references, failedFilenames: failed)
    }
}
