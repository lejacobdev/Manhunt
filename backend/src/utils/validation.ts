import { ZodError } from 'zod';

/**
 * Flattens a ZodError into a single human-readable string. Every client
 * (the iOS app included) decodes error responses as `{ error: string }`,
 * so returning `error.flatten()` directly — an object — silently fails to
 * decode client-side and surfaces as a generic "request failed with status
 * 400" instead of the actual validation reason.
 */
export function zodErrorMessage(error: ZodError): string {
  return error.issues
    .map((issue) => {
      const path = issue.path.join('.');
      return path ? `${path}: ${issue.message}` : issue.message;
    })
    .join(' ');
}
