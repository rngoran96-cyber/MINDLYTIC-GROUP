// Crée une session de paiement Wave pour le gestionnaire connecté.
// Secrets requis : WAVE_API_KEY, SITE_URL (https://...). Optionnel : WAVE_SIGNING_SECRET (si la signature de requêtes est activée sur la clé).
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Content-Type": "application/json",
};
const reply = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: cors });

async function hmacHex(secret: string, data: string) {
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sig = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(data));
  return [...new Uint8Array(sig)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const supa = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, {
      global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
    });
    const { data: { user } } = await supa.auth.getUser();
    if (!user) return reply({ error: "Non connecté" }, 401);

    const { data: prof } = await supa.from("profiles").select("role").eq("id", user.id).maybeSingle();
    if (prof?.role !== "admin") return reply({ error: "Réservé aux gestionnaires" }, 403);

    // Le type et le prix sont décidés ici, jamais par le navigateur.
    const { data: sub } = await supa.from("subscriptions").select("setup_paid").maybeSingle();
    const kind = sub?.setup_paid ? "MENSUEL" : "ACTIVATION";
    const { data: amount, error: pe } = await supa.rpc("price_of", { k: kind });
    if (pe || !amount) return reply({ error: "Prix introuvable" }, 500);

    const site = (Deno.env.get("SITE_URL") ?? "").replace(/\/$/, "");
    const body = JSON.stringify({
      amount: String(amount),
      currency: "XOF",
      success_url: `${site}/?paiement=ok`,
      error_url: `${site}/?paiement=erreur`,
      client_reference: `${user.id}|${kind}`,
    });
    const headers: Record<string, string> = {
      Authorization: `Bearer ${Deno.env.get("WAVE_API_KEY")}`,
      "Content-Type": "application/json",
    };
    const signing = Deno.env.get("WAVE_SIGNING_SECRET");
    if (signing) {
      const t = Math.floor(Date.now() / 1000);
      headers["Wave-Signature"] = `t=${t},v1=${await hmacHex(signing, `${t}${body}`)}`;
    }
    const r = await fetch("https://api.wave.com/v1/checkout/sessions", { method: "POST", headers, body });
    const j = await r.json().catch(() => ({}));
    if (!r.ok || !j.wave_launch_url) {
      console.error("Wave checkout error", r.status, JSON.stringify(j));
      return reply({ error: "Wave a refusé la demande (" + (j.code ?? j.error_code ?? r.status) + ")" }, 502);
    }
    return reply({ url: j.wave_launch_url, kind, amount });
  } catch (e) {
    console.error(e);
    return reply({ error: "Erreur interne" }, 500);
  }
});
