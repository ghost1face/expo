// Copyright 2015-present 650 Industries. All rights reserved.

import Foundation

/**
 `URLRequest.httpBodyData()` extension to read the underlying `httpBodyStream` as Data.
 */
extension URLRequest {
  func httpBodyData(limit: Int = ExpoRequestInterceptorProtocol.MAX_BODY_SIZE) -> Data? {
    if let httpBody = self.httpBody {
      return httpBody
    }

    // Never drain one-shot streaming upload bodies for DevTools. Re-reading httpBodyStream
    // after URLSession already consumes it hangs inspectors and can stall the request.
    if URLProtocol.property(forKey: "ExpoFetchStreamingRequestBody", in: self) as? Bool == true {
      return nil
    }

    if let contentLength = self.allHTTPHeaderFields?["Content-Length"],
      let contentLengthInt = Int(contentLength),
      contentLengthInt > limit {
      return nil
    }
    guard let stream = self.httpBodyStream else {
      return nil
    }

    let bufferSize: Int = 8192
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)

    stream.open()
    defer {
      buffer.deallocate()
      stream.close()
    }

    var data = Data()
    while stream.hasBytesAvailable {
      let chunkSize = stream.read(buffer, maxLength: bufferSize)
      if chunkSize < 0 {
        return nil
      }
      if chunkSize == 0 {
        break
      }
      if data.count + chunkSize > limit {
        return nil
      }
      data.append(buffer, count: chunkSize)
    }

    return data
  }
}
