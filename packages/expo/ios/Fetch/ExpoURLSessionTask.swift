// Copyright 2015-present 650 Industries. All rights reserved.

import ExpoModulesCore

/**
 An URLSessionDataTask wrapper.
 */
internal final class ExpoURLSessionTask: NSObject, URLSessionTaskDelegate, URLSessionDataDelegate, @unchecked Sendable {
  private let delegate: ExpoURLSessionTaskDelegate
  private var task: URLSessionDataTask?

  init(delegate: ExpoURLSessionTaskDelegate) {
    self.delegate = delegate
    super.init()
  }

  func start(
    urlSession: URLSession,
    urlSessionDelegate: URLSessionSessionDelegateProxy,
    url: URL,
    requestInit: NativeRequestInit,
    requestBody: Data?
  ) {
    let request = buildRequest(url: url, requestInit: requestInit)
    request.httpBody = requestBody
    resume(urlSession: urlSession, urlSessionDelegate: urlSessionDelegate, request: request as URLRequest)
  }

  func startWithStreamingBody(
    urlSession: URLSession,
    urlSessionDelegate: URLSessionSessionDelegateProxy,
    url: URL,
    requestInit: NativeRequestInit,
    bodyStream: RequestBodyStream
  ) {
    let request = buildRequest(url: url, requestInit: requestInit)
    // Omit Content-Length so URLSession uses chunked transfer for the stream.
    request.setValue(nil, forHTTPHeaderField: "Content-Length")
    // Mark so DevTools does not drain the one-shot httpBodyStream for CDP postData.
    URLProtocol.setProperty(true, forKey: "ExpoFetchStreamingRequestBody", in: request)
    bodyStream.openIfNeeded()
    request.httpBodyStream = bodyStream.inputStream
    resume(urlSession: urlSession, urlSessionDelegate: urlSessionDelegate, request: request as URLRequest)
  }

  func cancel(urlSessionDelegate: URLSessionSessionDelegateProxy) {
    if let task {
      urlSessionDelegate.removeDelegate(task: task)
      task.cancel()
    }
  }

  private func buildRequest(url: URL, requestInit: NativeRequestInit) -> NSMutableURLRequest {
    let request = NSMutableURLRequest(url: url)
    URLProtocol.setProperty(requestInit.redirect == .follow, forKey: "shouldFollowRedirects", in: request)
    request.httpMethod = requestInit.method
    // No hard request ceiling for buffered or streaming uploads.
    request.timeoutInterval = 0
    if requestInit.credentials == .include {
      request.httpShouldHandleCookies = true
      if let cookies = HTTPCookieStorage.shared.cookies(for: url) {
        request.allHTTPHeaderFields = HTTPCookie.requestHeaderFields(with: cookies)
      }
    } else {
      request.httpShouldHandleCookies = false
    }
    for tuple in requestInit.headers {
      request.addValue(tuple[1], forHTTPHeaderField: tuple[0])
    }
    return request
  }

  private func resume(
    urlSession: URLSession,
    urlSessionDelegate: URLSessionSessionDelegateProxy,
    request: URLRequest
  ) {
    let task = urlSession.dataTask(with: request)
    urlSessionDelegate.addDelegate(task: task, delegate: self)
    self.task = task
    task.resume()
    self.delegate.urlSessionDidStart(self)
  }

  // MARK: - URLSessionTaskDelegate/URLSessionDataDelegate implementations

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    self.delegate.urlSession(
      self,
      task: task,
      willPerformHTTPRedirection: response,
      newRequest: request,
      completionHandler: completionHandler)
  }

  func urlSession(
    _ session: URLSession,
    dataTask: URLSessionDataTask,
    didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    self.delegate.urlSession(self, didReceive: response)
    completionHandler(.allow)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    self.delegate.urlSession(self, didReceive: data)
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    self.delegate.urlSession(self, task: task, didCompleteWithError: error)
  }
}

internal protocol ExpoURLSessionTaskDelegate: AnyObject, Sendable {
  func urlSessionDidStart(_ session: ExpoURLSessionTask)
  func urlSession(_ session: ExpoURLSessionTask, didReceive response: URLResponse)
  func urlSession(_ session: ExpoURLSessionTask, didReceive data: Data)
  func urlSession(
    _ session: ExpoURLSessionTask,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  )
  func urlSession(_ session: ExpoURLSessionTask, task: URLSessionTask, didCompleteWithError error: Error?)
}
