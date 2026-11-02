//
//  URLSessionWebSocketTransport.swift
//  Netti
//
//  Created by El Mostafa El Ouatri on 27/10/26.
//

import Foundation
import os

/// A ``WebSocketTransport`` over an open `URLSessionWebSocketTask`.
///
/// A `URLSessionWebSocketTask` only processes incoming frames, pongs included, while a
/// `receive()` is pending, so a ping sent with no read outstanding never completes. This transport
/// therefore keeps exactly one read pending for the life of the connection and buffers what it
/// reads into ``messages``. Releasing the transport closes the connection with `goingAway`.
///
/// When the consumer falls more than `maximumBufferedMessages` messages or `maximumBufferedBytes`
/// bytes behind, ``messages`` fails with ``HTTPRequestError/requestFailed(_:)`` carrying
/// `URLError.dataLengthExceedsMaximum` and the connection is closed.
final class URLSessionWebSocketTransport: WebSocketTransport {

    // MARK: - Types

    private typealias PingContinuation = CheckedContinuation<HTTPRequestError?, Never>

    // MARK: - Constants

    /// Close codes after which the end of the connection is not an error.
    private static let normalCloseCodes: Set<URLSessionWebSocketTask.CloseCode> = [.normalClosure, .goingAway]

    // MARK: - Properties

    let messages: AsyncThrowingStream<WebSocketMessage, any Error>

    private let task: URLSessionWebSocketTask
    private let reader: Task<Void, Never>

    // MARK: - Initialization

    /// Creates a transport and starts reading.
    ///
    /// - Parameters:
    ///   - task: The open WebSocket task.
    ///   - maximumBufferedMessages: The most unread messages buffered before ``messages`` fails.
    ///   - maximumBufferedBytes: The most unread bytes buffered before ``messages`` fails.
    init(
        task: URLSessionWebSocketTask,
        maximumBufferedMessages: Int = StreamBufferMeter.defaultMessageLimit,
        maximumBufferedBytes: Int = StreamBufferMeter.defaultByteLimit
    ) {
        let (messages, continuation) = AsyncThrowingStream<WebSocketMessage, any Error>.makeStream(
            bufferingPolicy: .bufferingOldest(maximumBufferedMessages)
        )
        self.task = task
        self.messages = messages
        self.reader = Task {
            await Self.read(task, into: continuation, messageLimit: maximumBufferedMessages, byteLimit: maximumBufferedBytes)
        }
    }

    deinit {
        reader.cancel()
        task.cancel(with: .goingAway, reason: nil)
    }

    // MARK: - WebSocketTransport

    func send(_ message: WebSocketMessage) async throws(HTTPRequestError) {
        let taskMessage: URLSessionWebSocketTask.Message = switch message {
            case .text(let text):
                .string(text)
            case .data(let data):
                .data(data)
        }
        do {
            try await task.send(taskMessage)
        } catch {
            throw .transport(error)
        }
    }

    func sendPing() async throws(HTTPRequestError) {
        let pending = OSAllocatedUnfairLock<PingContinuation?>(initialState: nil)
        let resumeOnce: @Sendable (HTTPRequestError?) -> Void = { failure in
            pending.withLock { pending in
                defer { pending = nil }
                return pending
            }?.resume(returning: failure)
        }
        let failure = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                pending.withLock { $0 = continuation }
                task.sendPing { error in
                    resumeOnce(error.map(HTTPRequestError.transport))
                }
                if Task.isCancelled {
                    resumeOnce(.cancelled)
                }
            }
        } onCancel: {
            resumeOnce(.cancelled)
        }
        if let failure {
            throw failure
        }
    }

    func close(with code: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        task.cancel(with: code, reason: reason)
    }
}

// MARK: - Private Methods

private extension URLSessionWebSocketTransport {
    /// Reads until the connection ends, then finishes `continuation`: normally after a normal
    /// close code, with the transport error otherwise, and with `URLError.dataLengthExceedsMaximum`
    /// when the consumer falls more than `messageLimit` messages or `byteLimit` bytes behind.
    static func read(
        _ task: URLSessionWebSocketTask,
        into continuation: AsyncThrowingStream<WebSocketMessage, any Error>.Continuation,
        messageLimit: Int,
        byteLimit: Int
    ) async {
        var buffer = StreamBufferMeter()
        while true {
            do {
                let message: WebSocketMessage
                let size: Int
                switch try await task.receive() {
                    case .string(let text):
                        message = .text(text)
                        size = text.utf8.count
                    case .data(let data):
                        message = .data(data)
                        size = data.count
                    @unknown default:
                        continue
                }
                let isOverflowing = switch continuation.yield(message) {
                    case .enqueued(let remaining):
                        buffer.record(size: size, bufferedCount: messageLimit - remaining) > byteLimit
                    case .dropped:
                        true
                    case .terminated:
                        false
                    @unknown default:
                        false
                }
                if isOverflowing {
                    continuation.finish(throwing: HTTPRequestError.requestFailed(URLError(.dataLengthExceedsMaximum)))
                    task.cancel(with: .goingAway, reason: nil)
                    return
                }
            } catch {
                if normalCloseCodes.contains(task.closeCode) {
                    continuation.finish()
                } else {
                    continuation.finish(throwing: HTTPRequestError.transport(error))
                }
                return
            }
        }
    }
}
