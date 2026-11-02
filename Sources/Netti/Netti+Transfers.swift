//
//  Netti+Transfers.swift
//  Netti
//
//  Created by El Mostafa El Ouatri on 28/10/26.
//

import Foundation
import os

/// The HTTP method of an upload.
public enum UploadMethod: String, Sendable {
    /// Uploads with `POST`, the default.
    case post = "POST"
    /// Uploads with `PUT`.
    case put = "PUT"
    /// Uploads with `PATCH`.
    case patch = "PATCH"

    var httpMethod: HTTPMethod {
        switch self {
            case .post: .post
            case .put: .put
            case .patch: .patch
        }
    }
}

/// What a download does when it moves its file to the destination.
public struct DownloadOptions: OptionSet, Sendable {
    /// The bit mask of the options.
    public let rawValue: Int

    /// Creates options from a bit mask.
    ///
    /// - Parameter rawValue: The bit mask.
    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// Creates the destination's missing parent directories.
    public static let createIntermediateDirectories = DownloadOptions(rawValue: 1 << 0)

    /// Replaces a file already at the destination.
    public static let removePreviousFile = DownloadOptions(rawValue: 1 << 1)
}

/// Uploads and downloads, with optional progress.
///
/// ```swift
/// let receipt: Receipt? = try await netti.upload(ReceiptAPI.scan, fileURL: photoURL).data
/// let file = try await netti.download(MapAPI.tiles, to: tilesURL).fileURL
/// ```
///
/// Progress handlers run on a background queue with increasing values and end at `1.0` on success.
extension Netti {

    // MARK: - Upload

    /// Uploads in-memory data as the request body.
    ///
    /// ```swift
    /// let receipt: Receipt? = try await netti.upload(ReceiptAPI.scan, data: jpegData) { fraction in
    ///     uploadProgress = fraction
    /// }.data
    /// ```
    ///
    /// - Parameters:
    ///   - endpoint: The endpoint.
    ///   - data: The body.
    ///   - method: `POST` by default.
    ///   - progress: Called as the body is sent. Optional.
    /// - Returns: The decoded response.
    /// - Throws: ``HTTPRequestError``.
    @_disfavoredOverload
    public func upload<Response: Decodable & Sendable>(
        _ endpoint: some HTTPRequest,
        data: Data,
        method: UploadMethod = .post,
        progress: ProgressHandler? = nil
    ) async throws(HTTPRequestError) -> HTTPResponse<Response> {
        try await upload(endpoint, source: .data(data), contentType: nil, method: method, progress: progress)
    }

    /// Uploads in-memory data and ignores the response body.
    ///
    /// - Parameters:
    ///   - endpoint: The endpoint.
    ///   - data: The body.
    ///   - method: `POST` by default.
    ///   - progress: Called as the body is sent. Optional.
    /// - Returns: The response, with an ``Empty`` body.
    /// - Throws: ``HTTPRequestError``.
    @discardableResult
    public func upload(
        _ endpoint: some HTTPRequest,
        data: Data,
        method: UploadMethod = .post,
        progress: ProgressHandler? = nil
    ) async throws(HTTPRequestError) -> HTTPResponse<Empty> {
        try await upload(endpoint, source: .data(data), contentType: nil, method: method, progress: progress)
    }

    /// Uploads the contents of a file, read from disk as it is sent.
    ///
    /// ```swift
    /// let receipt: Receipt? = try await netti.upload(ReceiptAPI.scan, fileURL: photoURL, method: .put).data
    /// ```
    ///
    /// - Parameters:
    ///   - endpoint: The endpoint.
    ///   - fileURL: The local file.
    ///   - method: `POST` by default.
    ///   - progress: Called as the body is sent. Optional.
    /// - Returns: The decoded response.
    /// - Throws: ``HTTPRequestError/fileSystem(_:)`` before any network traffic when the file
    ///   cannot be read; otherwise ``HTTPRequestError``.
    @_disfavoredOverload
    public func upload<Response: Decodable & Sendable>(
        _ endpoint: some HTTPRequest,
        fileURL: URL,
        method: UploadMethod = .post,
        progress: ProgressHandler? = nil
    ) async throws(HTTPRequestError) -> HTTPResponse<Response> {
        try await upload(endpoint, source: .file(fileURL), contentType: nil, method: method, progress: progress)
    }

    /// Uploads the contents of a file and ignores the response body.
    ///
    /// - Parameters:
    ///   - endpoint: The endpoint.
    ///   - fileURL: The local file.
    ///   - method: `POST` by default.
    ///   - progress: Called as the body is sent. Optional.
    /// - Returns: The response, with an ``Empty`` body.
    /// - Throws: ``HTTPRequestError/fileSystem(_:)`` before any network traffic when the file
    ///   cannot be read; otherwise ``HTTPRequestError``.
    @discardableResult
    public func upload(
        _ endpoint: some HTTPRequest,
        fileURL: URL,
        method: UploadMethod = .post,
        progress: ProgressHandler? = nil
    ) async throws(HTTPRequestError) -> HTTPResponse<Empty> {
        try await upload(endpoint, source: .file(fileURL), contentType: nil, method: method, progress: progress)
    }

    /// Uploads a `multipart/form-data` body.
    ///
    /// A form over 10 MB is streamed from a temporary file that is deleted when the call returns.
    ///
    /// ```swift
    /// var form = MultipartFormData()
    /// form.append("Ada", name: "name")
    /// form.append(fileURL: avatarURL, name: "avatar")
    /// let profile: Profile? = try await netti.upload(ProfileAPI.update, multipart: form).data
    /// ```
    ///
    /// - Parameters:
    ///   - endpoint: The endpoint.
    ///   - multipart: The form; its boundary is sent in the `Content-Type` header.
    ///   - method: `POST` by default.
    ///   - progress: Called as the body is sent. Optional.
    /// - Returns: The decoded response.
    /// - Throws: ``HTTPRequestError``.
    @_disfavoredOverload
    public func upload<Response: Decodable & Sendable>(
        _ endpoint: some HTTPRequest,
        multipart: MultipartFormData,
        method: UploadMethod = .post,
        progress: ProgressHandler? = nil
    ) async throws(HTTPRequestError) -> HTTPResponse<Response> {
        try await uploadMultipart(endpoint, multipart: multipart, method: method, progress: progress)
    }

    /// Uploads a `multipart/form-data` body and ignores the response body.
    ///
    /// - Parameters:
    ///   - endpoint: The endpoint.
    ///   - multipart: The form; its boundary is sent in the `Content-Type` header.
    ///   - method: `POST` by default.
    ///   - progress: Called as the body is sent. Optional.
    /// - Returns: The response, with an ``Empty`` body.
    /// - Throws: ``HTTPRequestError``.
    @discardableResult
    public func upload(
        _ endpoint: some HTTPRequest,
        multipart: MultipartFormData,
        method: UploadMethod = .post,
        progress: ProgressHandler? = nil
    ) async throws(HTTPRequestError) -> HTTPResponse<Empty> {
        try await uploadMultipart(endpoint, multipart: multipart, method: method, progress: progress)
    }

    // MARK: - Download

    /// Downloads the response body to a file.
    ///
    /// Without a destination the file stays in a temporary directory; move it before the app
    /// relaunches. When the transfer fails or is cancelled after part of the body arrived, the
    /// error is ``HTTPRequestError/downloadFailed(_:resumeData:)``; pass its
    /// ``HTTPRequestError/resumeData`` back to continue:
    ///
    /// ```swift
    /// do {
    ///     let file = try await netti.download(VideoAPI.movie, to: movieURL).fileURL
    /// } catch {
    ///     resumeData = error.resumeData
    /// }
    /// let file = try await netti.download(VideoAPI.movie, to: movieURL, resumeData: resumeData).fileURL
    /// ```
    ///
    /// A resumed download sends the request stored in the resume data, with its original headers:
    /// interceptors, the `hosts:` scope of ``AuthenticationInterceptor`` and header validation do
    /// not apply to it again, so a token refreshed since is not used. Resume data whose URL differs
    /// from the endpoint's, or cannot be read, is discarded and the endpoint is downloaded fresh.
    ///
    /// - Parameters:
    ///   - endpoint: The endpoint, requested with `GET`.
    ///   - destination: Where the file is moved. `nil`, the default, keeps the temporary file.
    ///   - options: How the file is moved. Creates missing directories by default.
    ///   - resumeData: Data from a failed download of the same URL to continue from. Optional.
    ///   - progress: Called as the body is received. Optional.
    /// - Returns: The response; ``HTTPDownloadResponse/fileURL`` is the file's final location.
    /// - Throws: ``HTTPRequestError``.
    public func download(
        _ endpoint: some HTTPRequest,
        to destination: URL? = nil,
        options: DownloadOptions = .createIntermediateDirectories,
        resumeData: Data? = nil,
        progress: ProgressHandler? = nil
    ) async throws(HTTPRequestError) -> HTTPDownloadResponse<URL> {
        let urlRequest = try endpoint.asURLRequest(for: .get)
        let pipeline = snapshot.pipeline
        let service = pipeline.service
        let resumeState = OSAllocatedUnfairLock<Data?>(initialState: resumeData)

        let response: HTTPDownloadResponse<URL>
        do {
            response = try await pipeline.run(
                urlRequest,
                validation: endpoint.validation,
                retryPolicy: endpoint.retryPolicy,
                discard: { try? $0.fileURL.map(FileManager.default.removeItem(at:)) }
            ) { sent throws(HTTPRequestError) in
                let download = await service.download(for: sent, resumeData: resumeState.withLock { $0 }, progress: progress)
                resumeState.withLock { $0 = download.resumeData }
                if let error = download.error {
                    throw .transport(error)
                }
                let response = HTTPResponse<Data>(
                    request: download.request ?? sent,
                    response: download.response,
                    data: nil,
                    rawData: nil,
                    metrics: download.metrics
                )
                return RequestPipeline.Attempt(output: download, response: response)
            }
        } catch {
            guard let resumeData = resumeState.withLock({ $0 }) else {
                throw error
            }
            throw .downloadFailed(error, resumeData: resumeData)
        }

        guard let destination, let fileURL = response.fileURL else {
            return response
        }
        try move(fileURL, to: destination, options: options)
        return HTTPDownloadResponse(
            request: response.request,
            response: response.response,
            fileURL: destination,
            metrics: response.metrics
        )
    }
}

// MARK: - Private Helpers

private extension Netti {
    /// Encodes the form, in memory or to a temporary file deleted afterwards, and uploads it.
    func uploadMultipart<Response: Decodable & Sendable>(
        _ endpoint: some HTTPRequest,
        multipart: MultipartFormData,
        method: UploadMethod,
        progress: ProgressHandler?
    ) async throws(HTTPRequestError) -> HTTPResponse<Response> {
        let encoded = try multipart.encodedForUpload()
        defer {
            if case .file(let fileURL) = encoded {
                try? FileManager.default.removeItem(at: fileURL)
            }
        }
        let source: UploadSource = switch encoded {
            case .data(let data): .data(data)
            case .file(let fileURL): .file(fileURL)
        }
        return try await upload(endpoint, source: source, contentType: multipart.contentType, method: method, progress: progress)
    }

    func upload<Response: Decodable & Sendable>(
        _ endpoint: some HTTPRequest,
        source: UploadSource,
        contentType: String?,
        method: UploadMethod,
        progress: ProgressHandler?
    ) async throws(HTTPRequestError) -> HTTPResponse<Response> {
        try source.validate()
        var urlRequest = try endpoint.asURLRequest(for: method.httpMethod)
        if let contentType {
            urlRequest.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        let snapshot = self.snapshot
        let service = snapshot.pipeline.service
        let response = try await snapshot.pipeline.run(
            urlRequest,
            validation: endpoint.validation,
            retryPolicy: endpoint.retryPolicy
        ) { sent throws(HTTPRequestError) in
            let response = try await service.upload(for: sent, from: source, progress: progress)
            return RequestPipeline.Attempt(output: response, response: response)
        }
        return try decoded(response, using: snapshot)
    }

    func move(_ fileURL: URL, to destination: URL, options: DownloadOptions) throws(HTTPRequestError) {
        let fileManager = FileManager.default
        do {
            if options.contains(.createIntermediateDirectories) {
                try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            }
            if options.contains(.removePreviousFile), fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(at: fileURL, to: destination)
        } catch {
            try? fileManager.removeItem(at: fileURL)
            throw .fileSystem(error)
        }
    }
}
