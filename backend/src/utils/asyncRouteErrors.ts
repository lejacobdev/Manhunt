/**
 * Makes a rejected async route handler reach Express's error middleware.
 *
 * Express 4 only forwards errors a handler throws *synchronously* or passes to `next(err)`. An
 * `async` handler that rejects returns a rejected promise Express never looks at: the response is
 * never written, nothing is logged, and the request simply hangs until something upstream gives up.
 * Behind Cloudflare that surfaces as a bare 502 with no trace of a cause on our side.
 *
 * Found exactly that way — a Game Center sign-in rejection threw past its catch and the endpoint
 * answered 502 instead of 401, with an empty server log. Every `async` handler in this codebase has
 * the same shape, so this is fixed once here rather than by wrapping a hundred handlers and hoping
 * the next one remembers.
 *
 * With this installed, an unexpected rejection lands in server.ts's final error middleware and the
 * caller gets the same JSON error as any other failure.
 *
 * It works by patching `Layer.prototype.handle_request`, which is Express-internal but stable
 * across 4.x (the same approach the `express-async-errors` package takes, inlined here to avoid a
 * dependency for twenty lines). If that internal ever moves, the patch is skipped with a warning
 * rather than taking the server down on boot — Express 5 forwards rejections by itself, so the
 * fallback is "behaves like stock Express", not "broken".
 */

const WRAPPED = Symbol('asyncRouteErrorsWrapped');

type Handler = ((...args: unknown[]) => unknown) & { [WRAPPED]?: boolean };

export function installAsyncRouteErrorForwarding(): void {
  let Layer: { prototype: Record<string, unknown> };
  try {
    // eslint-disable-next-line @typescript-eslint/no-var-requires
    Layer = require('express/lib/router/layer');
  } catch (error) {
    console.warn('[Server] async route error forwarding not installed:', error);
    return;
  }

  const original = Layer.prototype.handle_request as
    | ((req: unknown, res: unknown, next: (err?: unknown) => void) => unknown)
    | undefined;
  if (typeof original !== 'function') {
    console.warn('[Server] async route error forwarding not installed: handle_request is not a function');
    return;
  }

  Layer.prototype.handle_request = function patched(
    this: { handle?: Handler },
    req: unknown,
    res: unknown,
    next: (err?: unknown) => void,
  ) {
    const fn = this.handle;
    // Arity 4 means it IS the error middleware; Express routes those through handle_error instead,
    // and wrapping one here would change how Express classifies it.
    if (typeof fn === 'function' && fn.length <= 3 && !fn[WRAPPED]) {
      const wrapped = function wrappedHandler(this: unknown, ...args: unknown[]) {
        const nextArg = args[2];
        const forward = typeof nextArg === 'function' ? (nextArg as (err?: unknown) => void) : next;
        let result: unknown;
        try {
          result = (fn as (...a: unknown[]) => unknown).apply(this, args);
        } catch (error) {
          forward(error);
          return undefined;
        }
        if (result && typeof (result as Promise<unknown>).then === 'function') {
          (result as Promise<unknown>).then(undefined, forward);
        }
        return result;
      } as Handler;
      wrapped[WRAPPED] = true;
      // Express reads `length` to tell handlers from error middleware, so it has to survive.
      Object.defineProperty(wrapped, 'length', { value: fn.length });
      Object.defineProperty(wrapped, 'name', { value: fn.name });
      this.handle = wrapped;
    }
    return original.call(this, req, res, next);
  };
}
