/**
 * Thin HTTP client for the zfsaas ZFinal backend.
 * Set ZFINAL_API_URL (e.g. http://127.0.0.1:8080). When unset, callers should
 * fall back to the existing Drizzle/server-action path.
 */
export function zfinalEnabled(): boolean {
  return base().length > 0;
}

function base() {
  if (typeof process === 'undefined') return '';
  return (process.env.ZFINAL_API_URL ?? '').replace(/\/$/, '');
}

export type ZfEnvelope<T> = {
  ok: boolean;
  data: T | null;
  error: string | null;
};

export async function zfFetch<T>(
  path: string,
  init: RequestInit & { token?: string } = {},
): Promise<ZfEnvelope<T>> {
  const url = `${base()}${path.startsWith('/') ? path : `/${path}`}`;
  const headers = new Headers(init.headers);
  headers.set('content-type', 'application/json');
  if (init.token) headers.set('authorization', `Bearer ${init.token}`);
  const { token: _t, ...rest } = init;
  const res = await fetch(url, { ...rest, headers });
  return (await res.json()) as ZfEnvelope<T>;
}

export async function signIn(email: string, password: string) {
  return zfFetch<{
    token: string;
    user: { id: number; email: string; name: string };
    org_id?: string;
    role?: string;
  }>('/api/auth/sign-in', {
    method: 'POST',
    body: JSON.stringify({ email, password }),
  });
}

export async function signUp(email: string, password: string, name: string) {
  return zfFetch<{
    token: string;
    user: { id: number; email: string; name: string };
    org_id?: string;
    role?: string;
  }>('/api/auth/sign-up', {
    method: 'POST',
    body: JSON.stringify({ email, password, name }),
  });
}

export async function me(token: string) {
  return zfFetch('/api/auth/me', { method: 'GET', token });
}

export async function listOrgs(token: string) {
  return zfFetch('/api/orgs', { method: 'GET', token });
}

export async function billingCheckout(token: string) {
  return zfFetch<{ url: string; mock: boolean }>('/api/billing/checkout', {
    method: 'POST',
    token,
  });
}
