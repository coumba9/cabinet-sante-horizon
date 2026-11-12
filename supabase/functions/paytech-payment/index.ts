const cors = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type', 'Access-Control-Allow-Methods': 'POST, OPTIONS' };
Deno.serve(req => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  return new Response(JSON.stringify({ error: 'payment_deferred', message: 'Le paiement est temporairement indisponible dans l’application.' }), {
    status: 410,
    headers: { ...cors, 'Content-Type': 'application/json' },
  });
});
