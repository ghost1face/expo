// Copyright 2015-present 650 Industries. All rights reserved.

import Foundation
import Testing
@testable import Expo

@Suite
struct RequestBodyStreamTests {
  @Test
  func `write chunks then finish yields EOF on input stream`() throws {
    let body = RequestBodyStream()
    body.openIfNeeded()

    try body.writeChunk(Data([1, 2, 3]))
    try body.writeChunk(Data([4, 5]))
    body.finish()

    var buffer = [UInt8](repeating: 0, count: 16)
    let firstRead = body.inputStream.read(&buffer, maxLength: buffer.count)
    #expect(firstRead == 5)
    #expect(Array(buffer.prefix(5)) == [1, 2, 3, 4, 5])

    let eof = body.inputStream.read(&buffer, maxLength: buffer.count)
    #expect(eof == 0)
  }

  @Test
  func `write after finish throws already closed`() throws {
    let body = RequestBodyStream()
    body.finish()

    #expect(throws: (any Error).self) {
      try body.writeChunk(Data([1]))
    }
  }

  @Test
  func `fail closes the output side`() throws {
    let body = RequestBodyStream()
    body.openIfNeeded()
    body.fail(
      NSError(domain: NSPOSIXErrorDomain, code: Int(EIO), userInfo: [
        NSLocalizedDescriptionKey: "Canceled"
      ])
    )

    #expect(throws: (any Error).self) {
      try body.writeChunk(Data([1]))
    }
  }

  @Test
  func `empty chunk write is a no-op before finish`() throws {
    let body = RequestBodyStream()
    try body.writeChunk(Data())
    try body.writeChunk(Data([9]))
    body.finish()

    var buffer = [UInt8](repeating: 0, count: 8)
    let read = body.inputStream.read(&buffer, maxLength: buffer.count)
    #expect(read == 1)
    #expect(buffer[0] == 9)
  }

  @Test
  func `finish from another thread unblocks a waiting reader`() throws {
    let body = RequestBodyStream()
    body.openIfNeeded()

    let group = DispatchGroup()
    group.enter()
    var readCount = -2

    DispatchQueue.global(qos: .userInitiated).async {
      var buffer = [UInt8](repeating: 0, count: 8)
      // Bound stream may block until the paired output is closed.
      readCount = body.inputStream.read(&buffer, maxLength: buffer.count)
      group.leave()
    }

    // Give the reader a moment to block on an empty stream.
    Thread.sleep(forTimeInterval: 0.05)
    body.finish()

    let waitResult = group.wait(timeout: .now() + 2.0)
    #expect(waitResult == .success)
    #expect(readCount == 0)
  }

  @Test
  func `fail from another thread prevents further writes`() throws {
    let body = RequestBodyStream()
    body.openIfNeeded()

    let group = DispatchGroup()
    group.enter()
    DispatchQueue.global(qos: .userInitiated).async {
      body.fail(
        NSError(domain: NSPOSIXErrorDomain, code: Int(EIO), userInfo: [
          NSLocalizedDescriptionKey: "Canceled"
        ])
      )
      group.leave()
    }

    let waitResult = group.wait(timeout: .now() + 2.0)
    #expect(waitResult == .success)

    #expect(throws: (any Error).self) {
      try body.writeChunk(Data([1]))
    }
  }
}
