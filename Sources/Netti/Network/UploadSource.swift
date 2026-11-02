//
//  UploadSource.swift
//  Netti
//
//  Created by El Mostafa El Ouatri on 27/10/26.
//

import Foundation

/// Where the body of an upload comes from.
public enum UploadSource: Sendable {
    /// An in-memory body.
    case data(Data)
    /// The contents of a local file, read as it is sent.
    case file(URL)
    /// A stream, created on demand. The engine may call the factory again when it has to resend
    /// the body (for example after a redirect), so return a new stream each time.
    case stream(@Sendable () -> InputStream)
}

extension UploadSource {
    /// The body size when known up front: the data size or the file size.
    var contentLength: Int64? {
        switch self {
            case .data(let data):
                Int64(data.count)
            case .file(let fileURL):
                (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
            case .stream:
                nil
        }
    }

    /// Fails with ``HTTPRequestError/fileSystem(_:)`` when a file source is not a readable file.
    package func validate() throws(HTTPRequestError) {
        guard case .file(let fileURL) = self else {
            return
        }
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory)
        guard exists, isDirectory.boolValue == false, FileManager.default.isReadableFile(atPath: fileURL.path) else {
            throw .fileSystem(CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: fileURL.path, NSURLErrorKey: fileURL]))
        }
    }
}
