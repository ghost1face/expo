// Copyright 2015-present 650 Industries. All rights reserved.

package expo.modules.fetch

import expo.modules.kotlin.AppContext
import expo.modules.kotlin.devtools.ExpoNetworkInspectOkHttpAppInterceptor
import expo.modules.kotlin.devtools.ExpoNetworkInspectOkHttpNetworkInterceptor
import expo.modules.kotlin.sharedobjects.SharedObject
import okhttp3.Call
import okhttp3.CookieJar
import okhttp3.MediaType
import okhttp3.MediaType.Companion.toMediaTypeOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody
import okhttp3.RequestBody.Companion.toRequestBody
import okio.BufferedSink
import java.io.IOException
import java.net.URL
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

private data class RequestHolder(var request: Request?)

internal val METHODS_REQUIRING_BODY = arrayOf("POST", "PUT", "PATCH")

/** Idle write timeout so a peer that stops reading after an early error status unblocks writeTo. */
private const val STREAMING_WRITE_TIMEOUT_SECONDS = 15L
/** 0 = no call timeout (OkHttp), so long-lived streaming uploads are not terminated by a hard ceiling. */
private const val STREAMING_CALL_TIMEOUT_SECONDS = 0L

internal fun buildRequestBody(method: String, requestBody: ByteArray?, mediaType: MediaType?): RequestBody? {
  return requestBody?.toRequestBody(mediaType) ?: run {
    // OkHttp requires a non-null body for POST/PATCH/PUT, unlike WinterTC fetch. Provide an empty
    // (zero-length) body to match it, not `byteArrayOf(0)`, which sends a single 0x00 byte.
    // Ref: https://github.com/expo/expo/issues/46668
    if (method in METHODS_REQUIRING_BODY) {
      ByteArray(0).toRequestBody(mediaType)
    } else {
      null
    }
  }
}

/**
 * Chunked, one-shot OkHttp body that drains [sink]. Non-duplex: JS finishes into the sink, then
 * OkHttp writes. Refuses a second [writeTo] so DevTools inspectors cannot hang.
 */
internal fun buildStreamingRequestBody(
  mediaType: MediaType?,
  sink: RequestSink,
  shouldStop: () -> Boolean = { false },
  getError: () -> Exception? = { null },
  onError: (Exception) -> Unit = {},
  onWriteFinished: () -> Unit = {}
): RequestBody {
  val bodyConsumed = AtomicBoolean(false)
  return object : RequestBody() {
    override fun contentType(): MediaType? = mediaType

    override fun contentLength(): Long = -1L

    override fun isOneShot(): Boolean = true

    override fun writeTo(out: BufferedSink) {
      // Expo DevTools CDP may call writeTo() again for postData after the network write.
      if (!bodyConsumed.compareAndSet(false, true)) {
        return
      }
      try {
        while (true) {
          when (val result = sink.takeChunk(timeoutMs = 250)) {
            is RequestSink.TakeResult.Chunk -> {
              out.write(result.data)
              out.emitCompleteSegments()
            }
            is RequestSink.TakeResult.End -> break
            is RequestSink.TakeResult.TimedOut -> {
              val error = getError()
              when {
                shouldStop() -> throw IOException("Canceled")
                error != null -> throw error
                else -> Unit
              }
            }
          }
        }
        out.flush()
      } catch (error: Exception) {
        onError(error)
        throw if (error is IOException) {
          error
        } else {
          IOException(error)
        }
      } finally {
        onWriteFinished()
      }
    }
  }
}

internal class NativeRequest(appContext: AppContext, internal val response: NativeResponse) :
  SharedObject(appContext) {
  private val requestHolder = RequestHolder(null)
  private var task: Call? = null
  @Volatile
  private var requestSink: RequestSink? = null
  @Volatile
  private var streamingError: Exception? = null

  fun start(client: OkHttpClient, url: URL, requestInit: NativeRequestInit, requestBody: ByteArray?) {
    clearStreamingBody()

    val headers = requestInit.headers.toHeaders()
    val mediaType = headers["Content-Type"]?.toMediaTypeOrNull()
    val reqBody = buildRequestBody(requestInit.method, requestBody, mediaType)
    enqueueRequest(client, url, requestInit, reqBody, streaming = false)
  }

  fun startWithStreamingBody(client: OkHttpClient, url: URL, requestInit: NativeRequestInit) {
    clearStreamingBody()
    val sink = RequestSink()
    requestSink = sink
    response.requestSink = sink

    val headers = requestInit.headers.toHeaders()
    val mediaType = headers["Content-Type"]?.toMediaTypeOrNull()
    // Non-duplex streaming upload: JS finishes the ReadableStream (or early-aborts) into the sink,
    // then OkHttp writes the queued body as a normal chunked request. isDuplex() hung waiting for
    // response headers on HTTP/1.1 and never settled waitForStreamingResponse.
    val reqBody = buildStreamingRequestBody(
      mediaType = mediaType,
      sink = sink,
      shouldStop = { task?.isCanceled() == true },
      getError = { streamingError },
      onError = { streamingError = it },
      onWriteFinished = {
        if (requestSink === sink) {
          requestSink = null
        }
        if (response.requestSink === sink) {
          response.requestSink = null
        }
      }
    )
    enqueueRequest(client, url, requestInit, reqBody, streaming = true)
  }

  fun sendBodyChunk(data: ByteArray) {
    val sink = requestSink
    if (sink != null) {
      sink.writeChunk(data)
      return
    }
    val error = streamingError
    if (error != null) {
      throw IOException("Streaming request body failed: ${error.message}", error)
    }
    throw IllegalStateException("No active streaming request body")
  }

  fun finishBody() {
    requestSink?.finish()
  }

  fun failBody(message: String) {
    val error = IOException(message)
    streamingError = error
    requestSink?.fail(error)
  }

  private fun clearStreamingBody() {
    requestSink = null
    response.requestSink = null
    streamingError = null
  }

  private fun enqueueRequest(
    client: OkHttpClient,
    url: URL,
    requestInit: NativeRequestInit,
    reqBody: RequestBody?,
    streaming: Boolean
  ) {
    val clientBuilder = client.newBuilder()
    if (requestInit.credentials != NativeRequestCredentials.INCLUDE) {
      clientBuilder.cookieJar(CookieJar.NO_COOKIES)
    }
    if (requestInit.redirect != NativeRequestRedirect.FOLLOW) {
      clientBuilder.followRedirects(false)
      clientBuilder.followSslRedirects(false)
    }
    if (streaming) {
      // RN's shared OkHttpClient often disables write timeouts (0 = infinite). When a server
      // answers early with 4xx/5xx and stops reading the body, write()/flush() then blocks on TCP
      // backpressure forever unless we reinstate a finite write timeout.
      clientBuilder.writeTimeout(STREAMING_WRITE_TIMEOUT_SECONDS, TimeUnit.SECONDS)
      // 0 disables OkHttp callTimeout so long-lived streaming uploads are not aborted mid-stream.
      clientBuilder.callTimeout(STREAMING_CALL_TIMEOUT_SECONDS, TimeUnit.SECONDS)
      // DevTools inspectors re-call RequestBody.writeTo for CDP postData. Safe to omit for
      // streaming uploads; without this, a nested inspector stack can still spam writeTo on cancel.
      clientBuilder.interceptors().removeAll { it is ExpoNetworkInspectOkHttpAppInterceptor }
      clientBuilder.networkInterceptors().removeAll { it is ExpoNetworkInspectOkHttpNetworkInterceptor }
    }

    val newClient = clientBuilder.build()
    response.redirectMode = requestInit.redirect

    val headers = requestInit.headers.toHeaders()
    val request = Request.Builder()
      .headers(headers)
      .method(requestInit.method, reqBody)
      .url(OkHttpFileUrlInterceptor.handleFileUrl(url))
      .build()
    this.requestHolder.request = request

    this.task = newClient.newCall(request)
    this.task?.enqueue(this.response)
    response.onStarted()
  }

  fun cancel() {
    val error = FetchRequestCanceledException()
    streamingError = error
    requestSink?.fail(IOException("Canceled"))
    requestSink = null
    response.requestSink = null
    val task = this.task ?: return
    task.cancel()
    response.emitRequestCanceled()
  }
}
