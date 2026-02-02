//
//  RequestQueue.swift
//  Netti
//
//  Created by El Mostafa El Ouatri on 30/01/26.
//

import Foundation

actor HTTPRequestQueue {
    private var continuations: [CheckedContinuation<Void, Error>] = []
    
    /// Suspends the current task until `resumeAll()` is called.
    func wait() async throws {
        try await withCheckedThrowingContinuation { continuation in
            continuations.append(continuation)
        }
    }
    
    /// Resumes all suspended tasks.
    func resumeAll() {
        continuations.forEach { $0.resume() }
        continuations.removeAll()
    }
    
    /// Cancels all pending tasks with an error.
    func cancelAll(error: Error) {
        continuations.forEach { $0.resume(throwing: error) }
        continuations.removeAll()
    }
}
