/// <reference types="node" />

/** @jest-environment node */

import { ReadableStream as WebReadableStream } from 'web-streams-polyfill';

import type { NativeRequest } from '../NativeRequest';
import { pumpReadableStreamToNativeRequest } from '../pumpReadableStreamToNativeRequest';

function createMockRequest(overrides: Partial<NativeRequest> = {}): NativeRequest & {
  chunks: Uint8Array[];
  finishCount: number;
  failMessages: string[];
} {
  const state = {
    chunks: [] as Uint8Array[],
    finishCount: 0,
    failMessages: [] as string[],
  };

  const request = {
    chunks: state.chunks,
    get finishCount() {
      return state.finishCount;
    },
    get failMessages() {
      return state.failMessages;
    },
    sendBodyChunk(chunk: Uint8Array) {
      state.chunks.push(chunk);
    },
    finishBody() {
      state.finishCount += 1;
    },
    failBody(message: string) {
      state.failMessages.push(message);
    },
    ...overrides,
  } as NativeRequest & {
    chunks: Uint8Array[];
    finishCount: number;
    failMessages: string[];
  };

  return request;
}

function streamFromChunks(chunks: Uint8Array[], close = true): ReadableStream<Uint8Array> {
  return new WebReadableStream<Uint8Array>({
    start(controller) {
      for (const chunk of chunks) {
        controller.enqueue(chunk);
      }
      if (close) {
        controller.close();
      }
    },
  }) as ReadableStream<Uint8Array>;
}

describe(pumpReadableStreamToNativeRequest, () => {
  it('pumps all chunks then finishes the native body', async () => {
    const request = createMockRequest();
    const a = new Uint8Array([1, 2]);
    const b = new Uint8Array([3, 4, 5]);

    await pumpReadableStreamToNativeRequest(streamFromChunks([a, b]), request);

    expect(request.chunks).toEqual([a, b]);
    expect(request.finishCount).toBe(1);
    expect(request.failMessages).toEqual([]);
  });

  it('skips empty chunks and still finishes an empty stream', async () => {
    const request = createMockRequest();

    await pumpReadableStreamToNativeRequest(
      streamFromChunks([new Uint8Array(0), new Uint8Array([9])]),
      request
    );

    expect(request.chunks).toEqual([new Uint8Array([9])]);
    expect(request.finishCount).toBe(1);

    const emptyRequest = createMockRequest();
    await pumpReadableStreamToNativeRequest(streamFromChunks([]), emptyRequest);
    expect(emptyRequest.chunks).toEqual([]);
    expect(emptyRequest.finishCount).toBe(1);
  });

  it('fail abort behavior fails the native body and throws', async () => {
    const request = createMockRequest();
    const controller = new AbortController();
    controller.abort();

    await expect(
      pumpReadableStreamToNativeRequest(
        streamFromChunks([new Uint8Array([1])]),
        request,
        controller.signal,
        'fail'
      )
    ).rejects.toThrow('The operation was aborted.');

    expect(request.failMessages).toEqual(['The operation was aborted.']);
    expect(request.finishCount).toBe(0);
  });

  it('soft abort behavior finishes the native body and resolves', async () => {
    const request = createMockRequest();
    const controller = new AbortController();
    controller.abort();

    await pumpReadableStreamToNativeRequest(
      streamFromChunks([new Uint8Array([1])]),
      request,
      controller.signal,
      'soft'
    );

    expect(request.finishCount).toBe(1);
    expect(request.failMessages).toEqual([]);
  });

  it('exits cleanly when sendBodyChunk reports the sink is already closed', async () => {
    const request = createMockRequest({
      sendBodyChunk() {
        throw new Error('Request body is already closed');
      },
    });

    await pumpReadableStreamToNativeRequest(streamFromChunks([new Uint8Array([1])]), request);

    expect(request.finishCount).toBe(1);
    expect(request.failMessages).toEqual([]);
  });

  it('exits cleanly when sendBodyChunk reports no active streaming body', async () => {
    const request = createMockRequest({
      sendBodyChunk() {
        throw new Error('No active streaming request body');
      },
    });

    await pumpReadableStreamToNativeRequest(streamFromChunks([new Uint8Array([1])]), request);

    expect(request.finishCount).toBe(1);
  });

  it('exits cleanly when sendBodyChunk reports Canceled', async () => {
    const request = createMockRequest({
      sendBodyChunk() {
        throw new Error('Canceled');
      },
    });

    await pumpReadableStreamToNativeRequest(streamFromChunks([new Uint8Array([1])]), request);

    expect(request.finishCount).toBe(1);
    expect(request.failMessages).toEqual([]);
  });

  it('soft-aborts cleanly when canceled mid-read', async () => {
    const request = createMockRequest();
    const controller = new AbortController();
    let resolveWait: (() => void) | undefined;
    const waitForRead = new Promise<void>((resolve) => {
      resolveWait = resolve;
    });

    const stream = new WebReadableStream<Uint8Array>({
      async pull(controllerInner) {
        resolveWait?.();
        await new Promise((resolve) => setTimeout(resolve, 50));
        if (!controller.signal.aborted) {
          controllerInner.enqueue(new Uint8Array([1]));
          controllerInner.close();
        }
      },
    }) as ReadableStream<Uint8Array>;

    const pumpPromise = pumpReadableStreamToNativeRequest(
      stream,
      request,
      controller.signal,
      'soft'
    );
    await waitForRead;
    controller.abort();
    await pumpPromise;

    expect(request.finishCount).toBe(1);
    expect(request.failMessages).toEqual([]);
  });

  it('fails the native body when the stream errors', async () => {
    const request = createMockRequest();
    const stream = new WebReadableStream<Uint8Array>({
      start(controller) {
        controller.error(new Error('stream boom'));
      },
    }) as ReadableStream<Uint8Array>;

    await expect(pumpReadableStreamToNativeRequest(stream, request)).rejects.toThrow('stream boom');
    expect(request.failMessages).toEqual(['stream boom']);
  });
});
