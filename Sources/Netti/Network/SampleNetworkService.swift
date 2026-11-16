//
//  SampleNetworkService.swift
//  Netti
//
//  Created by El Mostafa El Ouatri on 16/11/26.
//

import Foundation

#if DEBUG
/// A transport that answers data requests with an endpoint's sample instead of the network.
///
/// ``Netti`` runs a sampled request through its normal pipeline with this service in place of the
/// real one, so interceptors, validation, retry and monitors see the sample as a real response.
/// Every other call goes to the wrapped service.
struct SampleNetworkService: NetworkService {

    // MARK: - Properties

    let data: Data
    let statusCode: Int
    let delay: Duration?
    let wrapped: any NetworkService

    // MARK: - NetworkService

    /// Waits out the delay, then answers with the sample, its status and a JSON content type.
    func data(for request: URLRequest) async throws(HTTPRequestError) -> HTTPResponse<Data> {
        if let delay {
            do {
                try await Task.sleep(for: delay)
            } catch {
                throw .cancelled
            }
        }
        return HTTPResponse(
            request: request,
            response: HTTPURLResponse(
                url: request.url ?? URL(fileURLWithPath: "/"),
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            ),
            data: data,
            rawData: data
        )
    }

    func upload(
        for request: URLRequest,
        from source: UploadSource,
        progress: ProgressHandler?
    ) async throws(HTTPRequestError) -> HTTPResponse<Data> {
        try await wrapped.upload(for: request, from: source, progress: progress)
    }

    func download(
        for request: URLRequest,
        resumeData: Data?,
        progress: ProgressHandler?
    ) async -> HTTPDownloadResponse<URL> {
        await wrapped.download(for: request, resumeData: resumeData, progress: progress)
    }

    func bytes(for request: URLRequest) async throws(HTTPRequestError) -> HTTPStreamResponse {
        try await wrapped.bytes(for: request)
    }

    func webSocket(for request: URLRequest) async throws(HTTPRequestError) -> any WebSocketTransport {
        try await wrapped.webSocket(for: request)
    }
}
#endif
