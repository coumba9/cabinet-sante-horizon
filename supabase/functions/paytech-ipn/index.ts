import { createClient } from 'npm:@supabase/supabase-js@2';
import { supabaseSecretKey, supabaseUrl } from '../_shared/keys.ts';

const reply = (message: string, status = 200) => new Response(message, { status, headers: { 'Content-Type': 'text/plain; charset=utf-8' } });
const hex = (bytes: ArrayBuffer) => [...new Uint8Array(bytes)].map((byte) => byte.toString(16).padStart(2, '0')).join('');
const safeEqual = (left: string, right: string) => {
  if (left.length !== right.length) return false;
  let difference = 0;
  for (let i = 0; i < left.length; i++) difference |= left.charCodeAt(i) ^ right.charCodeAt(i);
  return difference === 0;
};
const sha256 = async (value: string) => hex(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(value)));
const hmac = async (secret: string, value: string) => {
  const key = await crypto.subtle.importKey('raw', new TextEncoder().encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  return hex(await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(value)));
};

Deno.serve(async (req) => {
  if (req.method !== 'POST') return reply('Method not allowed', 405);
  const apiKey = Deno.env.get('PAYTECH_API_KEY');
  const apiSecret = Deno.env.get('PAYTECH_API_SECRET');
  const serviceKey = supabaseSecretKey();
  if (!apiKey || !apiSecret || !serviceKey) return reply('Not configured', 503);

  let data: Record<string, unknown>;
  try {
    const contentType = req.headers.get('content-type') ?? '';
    if (contentType.includes('application/json')) data = await req.json();
    else {
      const form = await req.formData();
      data = Object.fromEntries([...form.entries()].map(([key, value]) => [key, String(value)]));
    }
  } catch { return reply('Invalid notification', 400); }

  const ref = String(data.ref_command ?? '');
  const event = String(data.type_event ?? '');
  const hmacValue = String(data.hmac_compute ?? '');
  const keyHash = String(data.api_key_sha256 ?? '');
  const secretHash = String(data.api_secret_sha256 ?? '');
  const price = String(data.final_item_price ?? data.item_price ?? data.final_item_price_xof ?? data.item_price_xof ?? '');
  if (!ref || !['sale_complete', 'sale_canceled'].includes(event) || !price) return reply('Invalid notification', 400);
  const valid = hmacValue
    ? safeEqual(await hmac(apiSecret, `${price}|${ref}|${apiKey}`), hmacValue.toLowerCase())
    : safeEqual(await sha256(apiKey), keyHash.toLowerCase()) && safeEqual(await sha256(apiSecret), secretHash.toLowerCase());
  if (!valid) return reply('Forbidden', 403);

  const amount = Number(price);
  if (!Number.isFinite(amount) || amount <= 0) return reply('Invalid amount', 400);
  const admin = createClient(supabaseUrl(), serviceKey, { auth: { autoRefreshToken: false, persistSession: false } });
  const { data: outcome, error } = await admin.rpc('paytech_process_ipn', {
    p_ref_command: ref,
    p_amount: amount,
    p_method: String(data.payment_method ?? ''),
    p_token: String(data.token ?? ''),
    p_event: event,
  });
  if (error) return reply('Payment processing failed', 500);
  if (outcome === 'amount_mismatch' || outcome === 'unknown_reference') return reply('Payment mismatch', 409);
  return reply('OK');
});
