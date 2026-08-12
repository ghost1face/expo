import { Platform } from 'react-native';

import { ExpoFetchModule } from './ExpoFetchModule';
import { FetchError } from './FetchErrors';
import { FetchResponse, type AbortSubscriptionCleanupFunction } from './FetchResponse';
import type { NativeRequest, NativeRequestInit } from './NativeRequest';
import {
  normalizeBodyInitAsync,
  normalizeHeadersInit,
  overrideHeaders,
  normalizeMethod,
} from './RequestUtils';
import type { FetchRequestInit, FetchRequestLike } from './fetch.types';
import { pumpReadableStreamToNativeRequest } from './pumpReadableStreamToNativeRequest';

/** Returns if `input` is a Request object */
const isRequest = (input: any): input is FetchRequestLike => {
  if (input == null || typeof input !== 'object') {
    return false;
  } else {
    return 'body' in input || input instanceof Request || input[Symbol.toStringTag] === 'Request';
  }
};

const dangerouslyGetBodyFromRequest = (
  input: FetchRequestLike | FetchRequestInit | undefined
): BodyInit | null => {
  if (input != null && input instanceof Request && '_bodyInit' in input) {
    // NOTE(@kitten): whatwg-fetch has a hidden property for the body input
    // TODO(@kitten): We should have our own Request class implementation
    return (input as any)._noBody !== true ? (input as any)._bodyInit : null;
  } else {
    return input?.body ?? null;
  }
};

function isReadableStreamBody(body: unknown): body is ReadableStream<Uint8Array> {
  return typeof ReadableStream !== 'undefined' && body instanceof ReadableStream;
}

function shouldStreamRequestBody(
  body: unknown,
  init?: FetchRequestInit
): body is ReadableStream<Uint8Array> {
  if (!isReadableStreamBody(body)) {
    return false;
  }

  // Honor fetch duplex semantics when provided; default to streaming on native for all streams.
  if (init?.duplex != null && init.duplex !== 'half') {
    return false;
  }

  return Platform.OS === 'android' || Platform.OS === 'ios';
}

// TODO(@kitten): Do we really want to use our own types for web standards?
export async function fetch(
  input: string | URL | FetchRequestLike,
  init?: FetchRequestInit
): Promise<FetchResponse> {
  const initFromRequest = isRequest(input);
  const url = initFromRequest ? input.url : input;
  const body =
    dangerouslyGetBodyFromRequest(init) ??
    (initFromRequest ? dangerouslyGetBodyFromRequest(input) : null);
  const signal = init?.signal ?? (initFromRequest ? input.signal : undefined);
  const redirect = init?.redirect ?? (initFromRequest ? input.redirect : undefined);
  const method = init?.method ?? (initFromRequest ? input.method : undefined);

  let credentials = init?.credentials ?? (initFromRequest ? input.credentials : undefined);
  if (credentials === 'same-origin') {
    credentials = 'include';
  }

  let headers = normalizeHeadersInit(
    init?.headers ?? (initFromRequest ? input.headers : undefined)
  );

  let abortSubscription: AbortSubscriptionCleanupFunction | null = null;
  // Soft-abort controller for response-driven pump exit (early headers). User abort uses cancel().
  let stopPump: AbortController | null = null;

  const response = new FetchResponse(() => {
    abortSubscription?.();
  });

  const request = new ExpoFetchModule.NativeRequest(response) as NativeRequest;

  const nativeRequestInit: NativeRequestInit = {
    credentials: credentials ?? 'include',
    headers,
    method: method != null ? normalizeMethod(method) : 'GET',
    redirect: redirect ?? 'follow',
  };

  if (signal && signal.aborted) {
    throw new FetchError('The operation was aborted.', { cause: signal.reason });
  }
  abortSubscription = addAbortSignalListener(signal, () => {
    // Abort the body stream before canceling the native request, so late
    // native events can't reach an abandoned controller.
    response.abort(signal?.reason);
    request.cancel();
    // Also unblock the pump if it is waiting on reader.read().
    stopPump?.abort();
  });
  try {
    if (shouldStreamRequestBody(body, init)) {
      // Sync: RequestSink must exist before JS pumps chunks.
      request.startWithStreamingBody(`${url}`, nativeRequestInit);

      // Register response waiter before pumping so we don't miss early headers (e.g. 4xx/5xx).
      const responsePromise = request.waitForStreamingResponse();

      // Critical: when headers arrive, the pump is often blocked on `reader.read()` (file I/O),
      // not on sendBodyChunk. finishBody() alone cannot unblock that — we must soft-abort the
      // ReadableStream reader so pump exits and fetch can return the status to middleware.
      stopPump = new AbortController();
      const stopPumpForResponse = () => {
        try {
          request.finishBody();
        } catch {
          // Body may already be failed/canceled.
        }
        if (!stopPump!.signal.aborted) {
          stopPump!.abort();
        }
      };
      void responsePromise.then(stopPumpForResponse, stopPumpForResponse);

      try {
        // Only the response-driven stopPump uses soft abort. User abort calls request.cancel()
        // above and then aborts stopPump so the pump exits without finish-vs-fail races.
        await pumpReadableStreamToNativeRequest(body, request, stopPump.signal, 'soft');
      } catch (pumpError: unknown) {
        if (signal?.aborted) {
          throw pumpError instanceof Error ? pumpError : new FetchError(String(pumpError));
        }
        // Prefer a settled HTTP response when the upload was cut short.
        try {
          await responsePromise;
        } catch {
          request.failBody(pumpError instanceof Error ? pumpError.message : String(pumpError));
          throw pumpError;
        }
      }

      await responsePromise;
    } else {
      const { body: requestBody, overriddenHeaders } = await normalizeBodyInitAsync(body);
      if (overriddenHeaders) {
        headers = overrideHeaders(headers, overriddenHeaders);
        nativeRequestInit.headers = headers;
      }
      await request.start(`${url}`, nativeRequestInit, requestBody);
    }
  } catch (e: unknown) {
    if (e instanceof Error) {
      throw FetchError.createFromError(e);
    } else {
      throw new FetchError(String(e));
    }
  }
  return response;
}

/**
 * A wrapper of `AbortSignal.addEventListener` that returns a cleanup function.
 */
function addAbortSignalListener(
  signal: AbortSignal | undefined,
  listener: Parameters<AbortSignal['addEventListener']>[1]
): AbortSubscriptionCleanupFunction {
  signal?.addEventListener('abort', listener);
  return () => {
    signal?.removeEventListener('abort', listener);
  };
}
