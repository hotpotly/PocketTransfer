import Foundation

// Body state runs on URLSession's serial delegate queue; completion is protected by lock.
final class BoundedResponse: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let limit: Int
    private let truncate: Bool
    private let accept: @Sendable (Int) -> Bool
    private var body = Data()
    private var rejected = false
    private var reachedLimit = false
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data?, Never>?
    private var completed = false
    private var result: Data?

    init(limit: Int, truncate: Bool, accept: @escaping @Sendable (Int) -> Bool) {
        self.limit = limit
        self.truncate = truncate
        self.accept = accept
    }

    func receive(using task: URLSessionDataTask) async -> Data? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.lock()
                if completed {
                    let result = result
                    lock.unlock()
                    continuation.resume(returning: result)
                } else {
                    self.continuation = continuation
                    lock.unlock()
                    task.resume()
                }
            }
        } onCancel: { task.cancel() }
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let response = response as? HTTPURLResponse, accept(response.statusCode),
            truncate || response.expectedContentLength <= Int64(limit) else {
            rejected = true
            completionHandler(.cancel)
            return
        }
        body.reserveCapacity(min(limit, max(0, Int(clamping: response.expectedContentLength))))
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let remaining = limit - body.count
        if data.count > remaining && !truncate {
            rejected = true
            dataTask.cancel()
            return
        }
        body.append(data.prefix(remaining))
        if truncate && body.count == limit {
            reachedLimit = true
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let result: Data? = !rejected && (error == nil || reachedLimit) ? body : nil
        lock.lock()
        self.result = result
        completed = true
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: result)
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
