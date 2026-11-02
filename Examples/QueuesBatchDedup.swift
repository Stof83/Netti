//
//  QueuesBatchDedup.swift
//  Netti
//

import Foundation
import NettiTesting

/// Concurrent requests with `async let`, batches that fail fast or keep every outcome, a
/// sequence, a priority queue, and in-flight deduplication.
///
/// Runs offline: a `StubServer` answers every request and counts what reaches it.
func queuesBatchDedupExample() async throws {
    let server = StubServer()
    let base = "https://api.example.com/v1"
    server.stub(.get, "\(base)/users", json: [User(id: 1, name: "Ada")])
    for id in 1...5 where id != 3 {
        server.stub(.get, "\(base)/users/\(id)", json: User(id: id, name: "User \(id)"))
    }
    server.stub(.get, "\(base)/users/3", error: URLError(.badServerResponse))
    let netti = server.netti()

    // MARK: - Different requests at once

    async let one: HTTPResponse<User> = netti.get(UserAPI.user(1))
    async let all: HTTPResponse<[User]> = netti.get(UserAPI.users)
    let (user, users) = try await (one, all)
    report("async let  -> \(user.data?.name ?? "nil") and \(users.data?.count ?? 0) users")

    // MARK: - Many inputs, fail fast

    // Annotate the result: nothing inside the closure names the type otherwise.
    let firstTwo: [User?] = try await netti.concurrent([1, 2], maxConcurrency: 2) { id in
        try await netti.get(UserAPI.user(id)).data
    }
    report("concurrent -> \(firstTwo.compactMap { $0?.name })")

    // MARK: - Many inputs, every outcome

    let outcomes = await netti.concurrentSettled(1...5) { (id: Int) -> User? in
        let response: HTTPResponse<User> = try await netti.get(UserAPI.user(id))
        return response.data
    }
    let failed = outcomes.enumerated().compactMap { index, outcome in
        if case .failure = outcome { index + 1 } else { nil }
    }
    report("settled    -> \(outcomes.count - failed.count) ok, failed ids: \(failed)")
    try expect(failed == [3], "expected only id 3 to fail, got \(failed)")

    // MARK: - One after another

    let names: [String?] = try await netti.sequential([1, 2]) { id in
        let response: HTTPResponse<User> = try await netti.get(UserAPI.user(id))
        return response.data?.name
    }
    report("sequential -> \(names.compactMap { $0 })")

    // MARK: - Priority queue

    // Pause, enqueue in the wrong order, resume: higher priorities start first.
    let queue = netti.queue(.serial)
    await queue.pause()
    let order = Recorder<String>()
    let jobs = [("low", RequestQueue.Priority.low), ("normal", .normal), ("high", .high)].map { name, priority in
        Task { try await queue.enqueue(priority: priority) { order.append(name) } }
    }
    while await queue.pendingCount < 3 {
        await Task.yield()
    }
    await queue.resume()
    for job in jobs {
        try await job.value
    }
    report("queue      -> ran in order \(order.values)")
    try expect(order.values == ["high", "normal", "low"], "unexpected order \(order.values)")

    // MARK: - In-flight deduplication

    // Five identical GETs while the first is in flight share one transfer.
    server.reset()
    server.stub(.get, "\(base)/users/1", json: User(id: 1, name: "Ada"), delay: .milliseconds(100))
    let _: [User?] = try await netti.concurrent(Array(repeating: 1, count: 5), maxConcurrency: 5) { id in
        try await netti.get(UserAPI.user(id)).data
    }
    report("dedup      -> 5 identical GETs, requests that reached the server: \(server.requests.count)")
    try expect(server.requests.count == 1, "expected 1 shared transfer, got \(server.requests.count)")
}
