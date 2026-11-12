import { errorMessage, parseRpcError, type RpcError } from "@famly/domain";

export class AppError extends Error {
  constructor(readonly rpc: RpcError) {
    super(errorMessage(rpc));
  }
}

/** Unwraps a supabase-js response, turning database errors into user-facing AppErrors. */
export function unwrap<T>(res: { data: T; error: { message: string; details?: string | null } | null }): NonNullable<T> {
  if (res.error) throw new AppError(parseRpcError(res.error));
  return res.data as NonNullable<T>;
}

export function messageOf(err: unknown): string {
  return err instanceof Error ? err.message : "Something went wrong. Please try again.";
}
