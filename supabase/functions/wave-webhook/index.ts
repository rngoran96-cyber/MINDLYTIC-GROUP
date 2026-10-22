// Reçoit les événements Wave. Active l'abonnement quand un paiement est réussi.
// Secrets requis : WAVE_WEBHOOK_SECRET (stratégie « Signing Secret »).
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";

async function hmacHex(secret: string, data: string) {
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sig = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(data));
  return [...new Uint8Array(sig)].map((b) => b.toString(16).padStart(2, "0")).join("");
}
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("method", { status: 405 });
  const raw = await req.text(); // corps brut : ne jamais le re-sérialiser avant de vérifier la signature
  const header = req.headers.get("Wave-Signature") ?? "";
  const parts = header.split(",");
  const t = parts.find((p) => p.startsWith("t="))?.slice(2);
  const sigs = parts.filter((p) => p.startsWith("v1=")).map((p) => p.slice(3));
  const secret = Deno.env.get("WAVE_WEBHOOK_SECRET");
  if (!secret || !t || !sigs.includes(await hmacHex(secret, t + raw)) || Math.abs(Date.now() / 1000 - Number(t)) > 300) {
    return new Response("invalid signature", { status: 401 });
  }

  const ev = JSON.parse(raw);
  if (ev.type !== "checkout.session.completed") return new Response("ignored", { status: 200 });
  const d = ev.data ?? {};
  if (d.payment_status !== "succeeded" || d.currency !== "XOF") return new Response("ignored", { status: 200 });

  const [adm, kind] = String(d.client_reference ?? "").split("|");
  if (!UUID.test(adm ?? "") || !["ACTIVATION", "MENSUEL"].includes(kind)) {
    console.error("client_reference invalide", d.client_reference);
    return new Response("ignored", { status: 200 });
  }

  const svc = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const { data, error } = await svc.rpc("apply_wave_payment", {
    adm, k: kind, amt: Number(d.amount), tx: String(d.transaction_id ?? d.id), sess: String(d.id),
  });
  if (error) {
    console.error(error);
    return new Response("error", { status: 500 }); // Wave réessaiera pendant 3 jours
  }
  if (data !== "ok") console.error("paiement non appliqué :", data, JSON.stringify(d));
  return new Response(String(data), { status: 200 });
});
