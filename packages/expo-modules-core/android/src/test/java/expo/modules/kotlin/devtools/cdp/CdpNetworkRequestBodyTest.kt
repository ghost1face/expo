// Copyright 2015-present 650 Industries. All rights reserved.

package expo.modules.kotlin.devtools.cdp

import com.google.common.truth.Truth.assertThat
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.RequestBody
import okio.BufferedSink
import org.junit.Test
import java.util.concurrent.atomic.AtomicInteger

class CdpNetworkRequestBodyTest {
  @Test
  fun `one-shot body is not drained for postData`() {
    val writeCount = AtomicInteger(0)
    val body = object : RequestBody() {
      override fun contentType() = "text/plain".toMediaType()
      override fun contentLength() = 5L
      override fun isOneShot() = true
      override fun writeTo(sink: BufferedSink) {
        writeCount.incrementAndGet()
        sink.writeUtf8("hello")
      }
    }

    val cdpRequest = Request(
      okhttp3.Request.Builder()
        .url("https://example.com/upload")
        .post(body)
        .build()
    )

    assertThat(cdpRequest.postData).isNull()
    assertThat(writeCount.get()).isEqualTo(0)
  }

  @Test
  fun `unknown length body is not drained for postData`() {
    val writeCount = AtomicInteger(0)
    val body = object : RequestBody() {
      override fun contentType() = "application/octet-stream".toMediaType()
      override fun contentLength() = -1L
      override fun writeTo(sink: BufferedSink) {
        writeCount.incrementAndGet()
        sink.writeUtf8("chunk")
      }
    }

    val cdpRequest = Request(
      okhttp3.Request.Builder()
        .url("https://example.com/upload")
        .post(body)
        .build()
    )

    assertThat(cdpRequest.postData).isNull()
    assertThat(writeCount.get()).isEqualTo(0)
  }

  @Test
  fun `buffered body is still captured for postData`() {
    val body = object : RequestBody() {
      override fun contentType() = "text/plain".toMediaType()
      override fun contentLength() = 5L
      override fun writeTo(sink: BufferedSink) {
        sink.writeUtf8("hello")
      }
    }

    val cdpRequest = Request(
      okhttp3.Request.Builder()
        .url("https://example.com/upload")
        .post(body)
        .build()
    )

    assertThat(cdpRequest.postData).isEqualTo("hello")
  }
}
