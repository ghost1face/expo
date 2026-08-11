// Copyright 2015-present 650 Industries. All rights reserved.

package expo.modules.fetch

import com.google.common.truth.Truth.assertThat
import org.junit.Assert.assertThrows
import org.junit.Test
import java.io.IOException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class RequestSinkTest {
  @Test
  fun `write and take chunks in order`() {
    val sink = RequestSink()
    sink.writeChunk(byteArrayOf(1, 2))
    sink.writeChunk(byteArrayOf(3))

    val first = sink.takeChunk(timeoutMs = 1000)
    val second = sink.takeChunk(timeoutMs = 1000)

    assertThat(first).isInstanceOf(RequestSink.TakeResult.Chunk::class.java)
    assertThat((first as RequestSink.TakeResult.Chunk).data.toList()).containsExactly(1.toByte(), 2.toByte())
    assertThat((second as RequestSink.TakeResult.Chunk).data.toList()).containsExactly(3.toByte())
  }

  @Test
  fun `finish yields End`() {
    val sink = RequestSink()
    sink.finish()

    assertThat(sink.takeChunk(timeoutMs = 1000)).isEqualTo(RequestSink.TakeResult.End)
  }

  @Test
  fun `fail surfaces error on take`() {
    val sink = RequestSink()
    sink.fail(IOException("boom"))

    val error = assertThrows(IOException::class.java) {
      sink.takeChunk(timeoutMs = 1000)
    }
    assertThat(error).hasMessageThat().isEqualTo("boom")
  }

  @Test
  fun `write after close throws`() {
    val sink = RequestSink()
    sink.finish()

    val error = assertThrows(IOException::class.java) {
      sink.writeChunk(byteArrayOf(1))
    }
    assertThat(error).hasMessageThat().contains("already closed")
  }

  @Test
  fun `timeout returns TimedOut without consuming end`() {
    val sink = RequestSink()

    assertThat(sink.takeChunk(timeoutMs = 50)).isEqualTo(RequestSink.TakeResult.TimedOut)

    sink.finish()
    assertThat(sink.takeChunk(timeoutMs = 1000)).isEqualTo(RequestSink.TakeResult.End)
  }

  @Test
  fun `concurrent writer and reader`() {
    val sink = RequestSink()
    val executor = Executors.newSingleThreadExecutor()
    val started = CountDownLatch(1)
    val done = CountDownLatch(1)

    executor.execute {
      started.countDown()
      repeat(20) { index ->
        sink.writeChunk(byteArrayOf(index.toByte()))
      }
      sink.finish()
      done.countDown()
    }

    assertThat(started.await(1, TimeUnit.SECONDS)).isTrue()

    val chunks = mutableListOf<Byte>()
    while (true) {
      when (val result = sink.takeChunk(timeoutMs = 1000)) {
        is RequestSink.TakeResult.Chunk -> chunks.addAll(result.data.toList())
        is RequestSink.TakeResult.End -> break
        is RequestSink.TakeResult.TimedOut -> Unit
      }
    }

    assertThat(done.await(1, TimeUnit.SECONDS)).isTrue()
    assertThat(chunks).hasSize(20)
    executor.shutdownNow()
  }
}
