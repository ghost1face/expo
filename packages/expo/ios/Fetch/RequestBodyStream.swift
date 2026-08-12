// Copyright 2015-present 650 Industries. All rights reserved.

import Foundation

/**
 Bridges JS ReadableStream chunks to a URLSession `httpBodyStream`.

 JS writes into an unbounded in-memory queue (never blocks the bridge thread). A background
 writer drains that queue into a bound `OutputStream` pair that URLSession reads from.
 */
internal final class RequestBodyStream: @unchecked Sendable {
  private static let boundBufferSize = 256 * 1024

  let inputStream: InputStream
  private let outputStream: OutputStream
  private let condition = NSCondition()
  private var pendingChunks: [Data] = []
  private var closed = false
  private var failure: Error?
  private var opened = false
  private var writerStarted = false
  private let writerQueue = DispatchQueue(label: "expo.modules.fetch.RequestBodyStream.writer")

  init() {
    var readStream: InputStream?
    var writeStream: OutputStream?
    Stream.getBoundStreams(
      withBufferSize: Self.boundBufferSize,
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
    condition.lock()
    defer { condition.unlock() }
    openIfNeededLocked()
  }

  func writeChunk(_ data: Data) throws {
    condition.lock()
    defer { condition.unlock() }
    openIfNeededLocked()
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
    if !data.isEmpty {
      pendingChunks.append(data)
      condition.broadcast()
    }
  }

  func finish() {
    condition.lock()
    defer { condition.unlock() }
    openIfNeededLocked()
    if closed {
      return
    }
    closed = true
    condition.broadcast()
  }

  func fail(_ error: Error) {
    condition.lock()
    defer { condition.unlock() }
    openIfNeededLocked()
    if closed {
      return
    }
    closed = true
    failure = error
    condition.broadcast()
  }

  private func openIfNeededLocked() {
    if opened {
      return
    }
    opened = true
    inputStream.open()
    outputStream.open()
    if !writerStarted {
      writerStarted = true
      writerQueue.async { [weak self] in
        self?.runWriter()
      }
    }
  }

  private func runWriter() {
    while true {
      let next: WriterWork
      condition.lock()
      while pendingChunks.isEmpty && !closed {
        condition.wait()
      }
      if !pendingChunks.isEmpty {
        next = .chunk(pendingChunks.removeFirst())
      } else if let failure {
        next = .fail(failure)
      } else {
        next = .finish
      }
      condition.unlock()

      switch next {
      case .chunk(let data):
        do {
          try writeFullyToOutput(data)
        } catch {
          condition.lock()
          closed = true
          failure = error
          pendingChunks.removeAll()
          condition.unlock()
          outputStream.close()
          return
        }
      case .finish, .fail:
        outputStream.close()
        return
      }
    }
  }

  private enum WriterWork {
    case chunk(Data)
    case finish
    case fail(Error)
  }

  private func writeFullyToOutput(_ data: Data) throws {
    if data.isEmpty {
      return
    }
    var offset = 0
    while offset < data.count {
      let written: Int = data.withUnsafeBytes { rawBuffer in
        guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else {
          return -1
        }
        return outputStream.write(base.advanced(by: offset), maxLength: data.count - offset)
      }
      if written < 0 {
        throw outputStream.streamError ?? NSError(
          domain: NSPOSIXErrorDomain,
          code: Int(EIO),
          userInfo: [NSLocalizedDescriptionKey: "Failed to write streaming request body"]
        )
      }
      if written == 0 {
        // Bound buffer full — wait on the writer queue only (never on the JS bridge thread).
        Thread.sleep(forTimeInterval: 0.01)
        continue
      }
      offset += written
    }
  }
}
