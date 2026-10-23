import { X509Certificate, createPublicKey, verify as cryptoVerify } from 'crypto';

/**
 * Verifies an App Store signed payload (a StoreKit 2 transaction's jwsRepresentation, or an App
 * Store Server Notification) the way Apple's own server libraries do: the JWS header carries a
 * three-certificate x5c chain that must end in Apple Root CA - G3 (embedded below, fingerprint
 * 63:34:3A:BF:…:91:79, downloaded from apple.com/certificateauthority), the leaf and intermediate
 * must carry Apple's App Store receipt-signing OIDs, every certificate must be within its validity
 * period, and the payload's ES256 signature must verify with the leaf's key.
 *
 * Anything a client sends is untrusted until this passes — it is the only thing standing between
 * "I bought the Supporter pack" and actually having bought it.
 */
const APPLE_ROOT_CA_G3 = new X509Certificate(Buffer.from('MIICQzCCAcmgAwIBAgIILcX8iNLFS5UwCgYIKoZIzj0EAwMwZzEbMBkGA1UEAwwSQXBwbGUgUm9vdCBDQSAtIEczMSYwJAYDVQQLDB1BcHBsZSBDZXJ0aWZpY2F0aW9uIEF1dGhvcml0eTETMBEGA1UECgwKQXBwbGUgSW5jLjELMAkGA1UEBhMCVVMwHhcNMTQwNDMwMTgxOTA2WhcNMzkwNDMwMTgxOTA2WjBnMRswGQYDVQQDDBJBcHBsZSBSb290IENBIC0gRzMxJjAkBgNVBAsMHUFwcGxlIENlcnRpZmljYXRpb24gQXV0aG9yaXR5MRMwEQYDVQQKDApBcHBsZSBJbmMuMQswCQYDVQQGEwJVUzB2MBAGByqGSM49AgEGBSuBBAAiA2IABJjpLz1AcqTtkyJygRMc3RCV8cWjTnHcFBbZDuWmBSp3ZHtfTjjTuxxEtX/1H7YyYl3J6YRbTzBPEVoA/VhYDKX1DyxNB0cTddqXl5dvMVztK517IDvYuVTZXpmkOlEKMaNCMEAwHQYDVR0OBBYEFLuw3qFYM4iapIqZ3r6966/ayySrMA8GA1UdEwEB/wQFMAMBAf8wDgYDVR0PAQH/BAQDAgEGMAoGCCqGSM49BAMDA2gAMGUCMQCD6cHEFl4aXTQY2e3v9GwOAEZLuN+yRhHFD/3meoyhpmvOwgPUnPWTxnS4at+qIxUCMG1mihDK1A3UT82NQz60imOlM27jbdoXt2QfyFMm+YhidDkLF1vLUagM6BgD56KyKA==', 'base64'));

// 1.2.840.113635.100.6.11.1 (App Store receipt signing, leaf) and 1.2.840.113635.100.6.2.1
// (Apple WWDR intermediate), DER-encoded as they appear in the certificates.
const LEAF_OID = Buffer.from('2a864886f76364060b01', 'hex');
const INTERMEDIATE_OID = Buffer.from('2a864886f76364060201', 'hex');

export class AppStoreVerificationError extends Error {}

function b64urlJson(part: string): any {
  return JSON.parse(Buffer.from(part, 'base64url').toString('utf8'));
}

export function verifyAppStoreJws<T = Record<string, unknown>>(jws: string, now: Date = new Date()): T {
  const parts = jws.split('.');
  if (parts.length !== 3) throw new AppStoreVerificationError('Not a signed App Store payload.');
  const header = b64urlJson(parts[0]);
  if (header.alg !== 'ES256' || !Array.isArray(header.x5c) || header.x5c.length !== 3) {
    throw new AppStoreVerificationError('Unexpected App Store signature format.');
  }
  const [leaf, intermediate, root] = header.x5c.map((c: string) => new X509Certificate(Buffer.from(c, 'base64')));

  if (root.fingerprint256 !== APPLE_ROOT_CA_G3.fingerprint256) {
    throw new AppStoreVerificationError('The signature does not chain to Apple.');
  }
  if (!intermediate.verify(APPLE_ROOT_CA_G3.publicKey) || !leaf.verify(intermediate.publicKey)) {
    throw new AppStoreVerificationError('The App Store certificate chain is broken.');
  }
  if (!leaf.raw.includes(LEAF_OID) || !intermediate.raw.includes(INTERMEDIATE_OID)) {
    throw new AppStoreVerificationError('Those are not App Store signing certificates.');
  }
  for (const cert of [leaf, intermediate]) {
    if (now < new Date(cert.validFrom) || now > new Date(cert.validTo)) {
      throw new AppStoreVerificationError('An App Store certificate has expired.');
    }
  }
  const ok = cryptoVerify(
    'sha256',
    Buffer.from(`${parts[0]}.${parts[1]}`),
    { key: createPublicKey(leaf.publicKey.export({ type: 'spki', format: 'pem' })), dsaEncoding: 'ieee-p1363' },
    Buffer.from(parts[2], 'base64url')
  );
  if (!ok) throw new AppStoreVerificationError('The App Store signature does not match.');
  return b64urlJson(parts[1]) as T;
}
