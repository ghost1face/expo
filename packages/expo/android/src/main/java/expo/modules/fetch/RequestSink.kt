// Copyright 2015-present 650 Industries. All rights reserved.

package expo.modules.fetch

import java.io.IOException
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

/**
 * Blocking queue bridging JS ReadableStream chunks to OkHttp's streaming RequestBody.
 */
internal class RequestSink {
  private sealed class QueueItem
  private object EndOfBody : QueueItem()
  private data class BodyChunk(val data: ByteArray) : QueueItem()

  private val lock = Any()
  private val queue = LinkedBlockingQueue<QueueItem>()
  @Volatile
  private var closed = false
  @Volatile
  private var failure: Exception? = null

  fun writeChunk(data: ByteArray) {
    synchronized(lock) {
      if (closed) {
        throw IOException("Request body is already closed")
      }
      queue.put(BodyChunk(data))
    }
  }

  fun finish() {
    synchronized(lock) {
      if (closed) {
        return
      }
      closed = true
      queue.put(EndOfBody)
    }
  }

  fun fail(error: Exception) {
    synchronized(lock) {
      if (closed) {
        return
      }
      closed = true
      failure = error
      queue.put(EndOfBody)
    }
  }

  /**
   * Blocks until a chunk is available or [timeoutMs] elapses.
   */
  fun takeChunk(timeoutMs: Long): TakeResult {
    val item = queue.poll(timeoutMs, TimeUnit.MILLISECONDS) ?: return TakeResult.TimedOut
    return when (item) {
      is BodyChunk -> TakeResult.Chunk(item.data)
      is EndOfBody -> {
        failure?.let { throw it }
        TakeResult.End
      }
    }
  }

  sealed class TakeResult {
    data class Chunk(val data: ByteArray) : TakeResult()
    data object End : TakeResult()
    data object TimedOut : TakeResult()
  }
}
