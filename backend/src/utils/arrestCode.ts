/**
 * Generates the short spoken/typed code a hunter must obtain from a runner
 * (verbally, or by scanning a QR derived from it) to confirm a legitimate catch.
 */
export function generateArrestCode(): string {
  const digits = Math.floor(1000 + Math.random() * 9000);
  return String(digits);
}

export function generateGameCode(): string {
  const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  let code = '';
  for (let i = 0; i < 6; i++) {
    code += alphabet[Math.floor(Math.random() * alphabet.length)];
  }
  return code;
}

export function generateUserTag(): string {
  return String(Math.floor(1000 + Math.random() * 9000));
}
