import type { SharedObject } from 'expo-modules-core';

export type NativeHeadersType = [string, string][];

export declare class NativeRequest extends SharedObject {
  public start(
    url: string,
    requestInit: NativeRequestInit,
    requestBody: Uint8Array | null
  ): Promise<NativeResponse>;
  /** Sync: create the native streaming body sink and enqueue the HTTP call. */
  public startWithStreamingBody(url: string, requestInit: NativeRequestInit): void;
  /** Resolves when headers/status are received (or the request fails). */
  public waitForStreamingResponse(): Promise<NativeResponse>;
  public sendBodyChunk(chunk: Uint8Array): void;
  public finishBody(): void;
  public failBody(message: string): void;
  public cancel(): void;
}

export interface NativeRequestInit {
  credentials?: RequestCredentials; // same-origin is not supported
  headers?: NativeHeadersType;
  method?: string;
  redirect?: RequestRedirect;
}

export type NativeResponseEvents = {
  didReceiveResponseData(data: Uint8Array): void;
  didComplete(): void;
  didFailWithError(error: string): void;
  readyForJSFinalization(): void;
};

export declare class NativeResponse extends SharedObject<NativeResponseEvents> {
  get bodyUsed(): boolean;
  get _rawHeaders(): NativeHeadersType;
  get status(): number;
  get statusText(): string;
  get url(): string;
  get redirected(): boolean;
  startStreaming(): Promise<Uint8Array<ArrayBuffer> | null>;
  cancelStreaming(reason: string): void;
  arrayBuffer(): Promise<ArrayBuffer>;
  text(): Promise<string>;
}
