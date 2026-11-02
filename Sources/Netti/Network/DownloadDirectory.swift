//
//  DownloadDirectory.swift
//  Netti
//
//  Created by El Mostafa El Ouatri on 27/10/26.
//

import Foundation

/// The temporary directory where engines place finished downloads before the caller moves them.
enum DownloadDirectory {

    // MARK: - Constants

    private static let name = "netti.downloads"

    // MARK: - Files

    /// A new, unused file URL inside the download directory, which is created if needed.
    ///
    /// - Throws: ``HTTPRequestError/fileSystem(_:)`` when the directory cannot be created.
    static func newFileURL() throws(HTTPRequestError) -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw .fileSystem(error)
        }
        return directory.appendingPathComponent(UUID().uuidString)
    }

    /// Moves a file the transport is about to delete into the download directory.
    ///
    /// - Parameter location: The transport's temporary file.
    /// - Returns: The file's new location.
    /// - Throws: ``HTTPRequestError/fileSystem(_:)`` when the move fails.
    static func claim(_ location: URL) throws(HTTPRequestError) -> URL {
        let destination = try newFileURL()
        do {
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            throw .fileSystem(error)
        }
        return destination
    }
}
