import { FetchError } from './FetchErrors';
import type { NativeRequest } from './NativeRequest';

export type PumpAbortBehavior = 'fail' | 'soft';

/**
 * Pumps a ReadableStream body to a native request without buffering the full body in JS.
 *
 * @param abortBehavior - `fail` (default): treat AbortSignal as a hard cancel (failBody + throw).
 *   `soft`: treat AbortSignal as "stop uploading, response already owns lifecycle" (finishBody, resolve).
 */
export async function pumpReadableStreamToNativeRequest(
  stream: ReadableStream<Uint8Array>,
  request: NativeRequest,
  signal?: AbortSignal | null,
  abortBehavior: PumpAbortBehavior = 'fail'
): Promise<void> {
  const reader = stream.getReader();
  let finished = false;

  const finishNativeBody = () => {
    if (!finished) {
      finished = true;
      request.finishBody();
    }
  };

  const failNativeBody = (message: string) => {
    if (!finished) {
      finished = true;
      request.failBody(message);
    }
  };

  const abortHandler = () => {
    reader.cancel('expo/fetch: upload aborted').catch(() => {});
    if (abortBehavior === 'soft') {
      finishNativeBody();
    } else {
      failNativeBody('The operation was aborted.');
    }
  };

  if (signal?.aborted) {
    abortHandler();
    if (abortBehavior === 'soft') {
      return;
    }
    throw new FetchError('The operation was aborted.');
  }

  signal?.addEventListener('abort', abortHandler);

  try {
    while (true) {
      if (signal?.aborted) {
        if (abortBehavior === 'soft') {
          finishNativeBody();
          return;
        }
        throw new FetchError('The operation was aborted.');
      }

      let done: boolean;
      let value: Uint8Array | undefined;
      try {
        ({ done, value } = await reader.read());
      } catch (readError: unknown) {
        // reader.cancel() rejects an in-flight read — exit cleanly on soft abort.
        if (signal?.aborted && abortBehavior === 'soft') {
          finishNativeBody();
          return;
        }
        throw readError;
      }

      if (done) {
        finishNativeBody();
        break;
      }

      if (value != null && value.byteLength > 0) {
        try {
          request.sendBodyChunk(value);
        } catch (error: unknown) {
          // Early HTTP response finishes/fails the native sink; exit so fetch can return status.
          const message = error instanceof Error ? error.message : String(error);
          if (
            message.includes('already closed') ||
            message.includes('No active streaming request body') ||
            message.includes('Streaming request body failed') ||
            message.includes('Canceled')
          ) {
            finishNativeBody();
            return;
          }
          throw error;
        }
      }
    }
  } catch (error: unknown) {
    if (signal?.aborted && abortBehavior === 'soft') {
      finishNativeBody();
      return;
    }
    if (!(error instanceof FetchError)) {
      failNativeBody(error instanceof Error ? error.message : String(error));
    }
    throw error;
  } finally {
    signal?.removeEventListener('abort', abortHandler);
    try {
      reader.releaseLock();
    } catch {
      // Reader may already be canceled.
    }
  }
}
