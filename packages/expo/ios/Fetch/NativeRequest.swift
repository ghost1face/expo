// Copyright 2015-present 650 Industries. All rights reserved.

import ExpoModulesCore

/**
 A SharedObject for request.
 */
internal final class NativeRequest: SharedObject, @unchecked Sendable {
  internal let response: NativeResponse
  internal let task: ExpoURLSessionTask
  private var bodyStream: RequestBodyStream?
  private var streamingError: Error?

  init(response: NativeResponse) {
    self.response = response
    self.task = ExpoURLSessionTask(delegate: self.response)
  }

  func start(
    urlSession: URLSession,
    urlSessionDelegate: URLSessionSessionDelegateProxy,
    url: URL,
    requestInit: NativeRequestInit,
    requestBody: Data?
  ) {
    clearStreamingBody()
    self.response.redirectMode = requestInit.redirect
    self.task.start(
      urlSession: urlSession,
      urlSessionDelegate: urlSessionDelegate,
      url: url,
      requestInit: requestInit,
      requestBody: requestBody
    )
  }

  func startWithStreamingBody(
    urlSession: URLSession,
    urlSessionDelegate: URLSessionSessionDelegateProxy,
    url: URL,
    requestInit: NativeRequestInit
  ) {
    clearStreamingBody()
    let stream = RequestBodyStream()
    bodyStream = stream
    response.requestBodyStream = stream
    self.response.redirectMode = requestInit.redirect
    self.task.startWithStreamingBody(
      urlSession: urlSession,
      urlSessionDelegate: urlSessionDelegate,
      url: url,
      requestInit: requestInit,
      bodyStream: stream
    )
  }

  func sendBodyChunk(_ data: Data) throws {
    if let bodyStream {
      try bodyStream.writeChunk(data)
      return
    }
    if let streamingError {
      throw NSError(
        domain: NSPOSIXErrorDomain,
        code: Int(EIO),
        userInfo: [
          NSLocalizedDescriptionKey: "Streaming request body failed: \(streamingError.localizedDescription)"
        ]
      )
    }
    throw NSError(
      domain: NSPOSIXErrorDomain,
      code: Int(EINVAL),
      userInfo: [NSLocalizedDescriptionKey: "No active streaming request body"]
    )
  }

  func finishBody() {
    bodyStream?.finish()
  }

  func failBody(_ message: String) {
    let error = NSError(
      domain: NSPOSIXErrorDomain,
      code: Int(EIO),
      userInfo: [NSLocalizedDescriptionKey: message]
    )
    streamingError = error
    bodyStream?.fail(error)
  }

  func cancel(urlSessionDelegate: URLSessionSessionDelegateProxy) {
    let error = FetchRequestCanceledException()
    streamingError = error
    bodyStream?.fail(error)
    bodyStream = nil
    response.requestBodyStream = nil
    self.task.cancel(urlSessionDelegate: urlSessionDelegate)
    self.response.emitRequestCanceled()
  }

  private func clearStreamingBody() {
    bodyStream = nil
    response.requestBodyStream = nil
    streamingError = nil
  }
}
