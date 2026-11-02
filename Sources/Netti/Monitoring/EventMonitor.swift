//
//  EventMonitor.swift
//  Netti
//

import Foundation

/// Observes the lifecycle of every request a client sends.
///
/// Every method has a no-op default, so a monitor implements only the events it needs. Events are
/// delivered synchronously, in order, from the task that runs the request; keep them cheap.
///
/// ```swift
/// struct SlowRequestMonitor: EventMonitor {
///     func requestDidCollectMetrics(_ metrics: URLSessionTaskMetrics, for request: URLRequest) {
///         if metrics.taskInterval.duration > 2 { report(request) }
///     }
/// }
/// ```
public protocol EventMonitor: Sendable {
    /// A request was built and is about to be adapted.
    ///
    /// - Parameter request: The request as built, before adaptation.
    func requestDidCreate(_ request: URLRequest)

    /// Adapters changed `original` into `adapted`.
    ///
    /// - Parameters:
    ///   - original: The request before adaptation.
    ///   - adapted: The request the adapters returned.
    func requestDidAdapt(_ original: URLRequest, to adapted: URLRequest)

    /// An attempt was handed to the transport.
    ///
    /// - Parameter request: The request as sent, after adaptation.
    func requestDidSend(_ request: URLRequest)

    /// A failed attempt will be sent again after `delay`; `retryCount` counts this retry.
    ///
    /// - Parameters:
    ///   - request: The request of the failed attempt.
    ///   - retryCount: The number of this retry, from 1.
    ///   - delay: The wait before the retry is sent.
    func requestWillRetry(_ request: URLRequest, retryCount: Int, delay: Duration)

    /// A response was received, whatever its status.
    ///
    /// - Parameter response: The raw response, before decoding.
    func requestDidReceiveResponse(_ response: HTTPResponse<Data>)

    /// The transport collected transfer metrics (timings, protocol, byte counts).
    ///
    /// - Parameters:
    ///   - metrics: The task metrics.
    ///   - request: The request the metrics describe.
    func requestDidCollectMetrics(_ metrics: URLSessionTaskMetrics, for request: URLRequest)

    /// The request failed for good.
    ///
    /// - Parameters:
    ///   - request: The request that failed.
    ///   - error: The error the call throws.
    func requestDidFail(_ request: URLRequest, error: HTTPRequestError)
}

extension EventMonitor {
    /// Ignores the creation event.
    ///
    /// - Parameter request: The request as built, before adaptation.
    public func requestDidCreate(_ request: URLRequest) {}

    /// Ignores the adaptation event.
    ///
    /// - Parameters:
    ///   - original: The request before adaptation.
    ///   - adapted: The request the adapters returned.
    public func requestDidAdapt(_ original: URLRequest, to adapted: URLRequest) {}

    /// Ignores the send event.
    ///
    /// - Parameter request: The request as sent, after adaptation.
    public func requestDidSend(_ request: URLRequest) {}

    /// Ignores the retry event.
    ///
    /// - Parameters:
    ///   - request: The request of the failed attempt.
    ///   - retryCount: The number of this retry, from 1.
    ///   - delay: The wait before the retry is sent.
    public func requestWillRetry(_ request: URLRequest, retryCount: Int, delay: Duration) {}

    /// Ignores the response event.
    ///
    /// - Parameter response: The raw response, before decoding.
    public func requestDidReceiveResponse(_ response: HTTPResponse<Data>) {}

    /// Ignores the metrics event.
    ///
    /// - Parameters:
    ///   - metrics: The task metrics.
    ///   - request: The request the metrics describe.
    public func requestDidCollectMetrics(_ metrics: URLSessionTaskMetrics, for request: URLRequest) {}

    /// Ignores the failure event.
    ///
    /// - Parameters:
    ///   - request: The request that failed.
    ///   - error: The error the call throws.
    public func requestDidFail(_ request: URLRequest, error: HTTPRequestError) {}
}

/// Forwards every event to its monitors, in registration order.
public struct CompositeEventMonitor: EventMonitor {
    private let monitors: [any EventMonitor]

    /// Creates a composite.
    ///
    /// - Parameter monitors: The monitors to forward to, in order.
    public init(_ monitors: [any EventMonitor]) {
        self.monitors = monitors
    }

    /// Forwards the creation event to every monitor, in order.
    ///
    /// - Parameter request: The request as built, before adaptation.
    public func requestDidCreate(_ request: URLRequest) {
        monitors.forEach { $0.requestDidCreate(request) }
    }

    /// Forwards the adaptation event to every monitor, in order.
    ///
    /// - Parameters:
    ///   - original: The request before adaptation.
    ///   - adapted: The request the adapters returned.
    public func requestDidAdapt(_ original: URLRequest, to adapted: URLRequest) {
        monitors.forEach { $0.requestDidAdapt(original, to: adapted) }
    }

    /// Forwards the send event to every monitor, in order.
    ///
    /// - Parameter request: The request as sent, after adaptation.
    public func requestDidSend(_ request: URLRequest) {
        monitors.forEach { $0.requestDidSend(request) }
    }

    /// Forwards the retry event to every monitor, in order.
    ///
    /// - Parameters:
    ///   - request: The request of the failed attempt.
    ///   - retryCount: The number of this retry, from 1.
    ///   - delay: The wait before the retry is sent.
    public func requestWillRetry(_ request: URLRequest, retryCount: Int, delay: Duration) {
        monitors.forEach { $0.requestWillRetry(request, retryCount: retryCount, delay: delay) }
    }

    /// Forwards the response event to every monitor, in order.
    ///
    /// - Parameter response: The raw response, before decoding.
    public func requestDidReceiveResponse(_ response: HTTPResponse<Data>) {
        monitors.forEach { $0.requestDidReceiveResponse(response) }
    }

    /// Forwards the metrics event to every monitor, in order.
    ///
    /// - Parameters:
    ///   - metrics: The task metrics.
    ///   - request: The request the metrics describe.
    public func requestDidCollectMetrics(_ metrics: URLSessionTaskMetrics, for request: URLRequest) {
        monitors.forEach { $0.requestDidCollectMetrics(metrics, for: request) }
    }

    /// Forwards the failure event to every monitor, in order.
    ///
    /// - Parameters:
    ///   - request: The request that failed.
    ///   - error: The error the call throws.
    public func requestDidFail(_ request: URLRequest, error: HTTPRequestError) {
        monitors.forEach { $0.requestDidFail(request, error: error) }
    }
}
