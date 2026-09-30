import type { Context, Next } from "hono";
import { getCookie, setCookie } from "hono/cookie";
import { createHash, randomBytes, timingSafeEqual } from "node:crypto";

// Reports and diagnostics hold users' recordings. Reading them needs the
// admin session; submitting them does not.

const COOKIE = "admin_session";
/** No default: without ADMIN_PASSWORD the admin area and read APIs stay closed. */
const PASSWORD = process.env.ADMIN_PASSWORD ?? "";
/** Per-process secret. The cookie carries it, so it cannot be forged; a restart signs out. */
const SESSION = randomBytes(32).toString("hex");

export const adminEnabled = PASSWORD.length > 0;

function same(a: string, b: string): boolean {
  const digest = (s: string) => createHash("sha256").update(s).digest();
  return timingSafeEqual(digest(a), digest(b));
}

export function checkPassword(candidate: unknown): boolean {
  return adminEnabled && typeof candidate === "string" && same(candidate, PASSWORD);
}

export function isAuthed(c: Context): boolean {
  const token = getCookie(c, COOKIE);
  return adminEnabled && typeof token === "string" && same(token, SESSION);
}

export function signIn(c: Context): void {
  // Path "/" so the dashboard's <audio> requests to /api/... carry it.
  setCookie(c, COOKIE, SESSION, { path: "/", httpOnly: true, sameSite: "Strict", maxAge: 86400 });
}

export async function requireAdmin(c: Context, next: Next): Promise<Response | void> {
  if (!isAuthed(c)) return c.json({ error: "Unauthorized" }, 401);
  await next();
}

/** Stored ids are server-made UUIDs; anything else never reaches the filesystem. */
export function isStoredId(id: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(id);
}

const HTML_ESCAPES: Record<string, string> = { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" };

/** Report fields are user input; escape before putting them in admin HTML. */
export function escapeHtml(value: unknown): string {
  return String(value ?? "").replace(/[&<>"']/g, (ch) => HTML_ESCAPES[ch]!);
}
