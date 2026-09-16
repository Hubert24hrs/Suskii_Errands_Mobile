// OTP SMS text. English for every country at launch: Pidgin SMS copy needs native-speaker
// review first (OD-20), and an OTP must be understood at a glance.
//
// When an Android SMS Retriever app hash is configured it is appended on its own line, which
// lets the app read the code without the READ_SMS permission (PRD SH-02 autofill).

export function otpMessage(otp: string, androidAppHash?: string): string {
  const body = `Your Suskii code is ${otp}. It expires soon. Never share it, not even with Suskii staff.`;
  return androidAppHash ? `${body}\n${androidAppHash}` : body;
}

export function isValidOtp(otp: unknown): otp is string {
  return typeof otp === "string" && /^[0-9]{6}$/.test(otp);
}
