/**
 * The one error class both identity verifiers throw, and the one the routes catch.
 *
 * It lives in its own file for a reason found the hard way: AppleIdentity and GameCenterIdentity
 * each declared their own `IdentityError`, the routes imported the Apple one, and
 * `error instanceof IdentityError` was therefore false for every Game Center rejection. The throw
 * escaped the handler, Express 4 does not catch a rejected async handler, and the request simply
 * hung until the proxy gave up with a 502 — no log line, no stack, nothing to see. A rejected
 * Game Center signature must answer 401, so there is exactly one class here.
 *
 * Its message is shown to the person verbatim, like every other error string in this API.
 */
export class IdentityError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'IdentityError';
  }
}
