// Copyright 2015-present 650 Industries. All rights reserved.

import Foundation

/**
 Bridges JS ReadableStream chunks to a URLSession `httpBodyStream` using a bound stream pair.
 The input stream is handed to URLSession; chunks are written to the paired output stream.
 */
internal final class RequestBodyStream: @unchecked Sendable {
  private static let bufferSize = 256 * 1024

  let inputStream: InputStream
  private let outputStream: OutputStream
  private let lock = NSLock()
  private var closed = false
  private var failure: Error?
  private var opened = false

  init() {
    var readStream: InputStream?
    var writeStream: OutputStream?
    Stream.getBoundStreams(
      withBufferSize: Self.bufferSize,
      inputStream: &readStream,
      outputStream: &writeStream
    )
    guard let input = readStream, let output = writeStream else {
      preconditionFailure("Failed to create bound streams for RequestBodyStream")
    }
    self.inputStream = input
    self.outputStream = output
  }

  func openIfNeeded() {
    lock.lock()
    defer { lock.unlock() }
    if opened {
      return
    }
    opened = true
    inputStream.open()
    outputStream.open()
  }

  func writeChunk(_ data: Data) throws {
    openIfNeeded()
    lock.lock()
    defer { lock.unlock() }
    if closed {
      throw NSError(
        domain: NSPOSIXErrorDomain,
        code: Int(EIO),
        userInfo: [NSLocalizedDescriptionKey: "Request body is already closed"]
      )
    }
    if let failure {
      throw NSError(
        domain: NSPOSIXErrorDomain,
        code: Int(EIO),
        userInfo: [
          NSLocalizedDescriptionKey: "Streaming request body failed: \(failure.localizedDescription)"
        ]
      )
    }
    try writeFully(data)
  }

  func finish() {
    openIfNeeded()
    lock.lock()
    defer { lock.unlock() }
    if closed {
      return
    }
    closed = true
    outputStream.close()
  }

  func fail(_ error: Error) {
    openIfNeeded()
    lock.lock()
    defer { lock.unlock() }
    if closed {
      return
    }
    closed = true
    failure = error
    outputStream.close()
  }

  private func writeFully(_ data: Data) throws {
    if data.isEmpty {
      return
    }
    var offset = 0
    while offset < data.count {
      if closed {
        throw NSError(
          domain: NSPOSIXErrorDomain,
          code: Int(EIO),
          userInfo: [NSLocalizedDescriptionKey: "Request body is already closed"]
        )
      }
      let written: Int = data.withUnsafeBytes { rawBuffer in
        guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else {
          return -1
        }
        return outputStream.write(base.advanced(by: offset), maxLength: data.count - offset)
      }
      if written < 0 {
        let error = outputStream.streamError ?? NSError(
          domain: NSPOSIXErrorDomain,
          code: Int(EIO),
          userInfo: [NSLocalizedDescriptionKey: "Failed to write streaming request body"]
        )
        failure = error
        closed = true
        outputStream.close()
        throw error
      }
      if written == 0 {
        // Bound buffer full — brief wait for URLSession to drain the input side.
        lock.unlock()
        Thread.sleep(forTimeInterval: 0.01)
        lock.lock()
        continue
      }
      offset += written
    }
  }
}
