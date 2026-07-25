// ClassNotes NOVA proxy — keeps the Groq API key server-side so it never ships
// in the app binary. The app sends its ClassMate session token; the proxy
// validates it against ClassMate's /auth/me, then forwards the (streaming)
// chat/completions request to Groq with the real key. That also gates the
// proxy so randoms can't burn the Groq quota — only signed-in ClassNotes users.
import express from "express";

const app = express();
app.use(express.json({ limit: "16mb" })); // vision requests carry base64 images

const GROQ_KEY = process.env.GROQ_API_KEY;
const GROQ_BASE = process.env.GROQ_BASE_URL || "https://api.groq.com/openai/v1";
const CM_API =
  process.env.CM_API_BASE_URL ||
  "https://pacific-enchantment-production-7a80.up.railway.app";
const PORT = process.env.PORT || 3000;

// Cache valid tokens briefly so we don't hit ClassMate on every NOVA turn.
const tokenCache = new Map(); // token -> expiry (ms)

async function isValid(token) {
  if (!token) return false;
  const now = Date.now();
  const cached = tokenCache.get(token);
  if (cached && cached > now) return true;
  try {
    const r = await fetch(`${CM_API}/auth/me`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    if (r.ok) {
      tokenCache.set(token, now + 60_000);
      return true;
    }
  } catch {
    /* fall through to 401 */
  }
  return false;
}

app.get("/health", (_req, res) => res.json({ ok: true }));

app.post("/openai/v1/chat/completions", async (req, res) => {
  const token = (req.headers.authorization || "").replace(/^Bearer\s+/i, "");
  if (!(await isValid(token))) {
    return res.status(401).json({ error: "Sign in to ClassNotes to use NOVA." });
  }
  if (!GROQ_KEY) {
    return res.status(500).json({ error: "Proxy is missing GROQ_API_KEY." });
  }
  try {
    const upstream = await fetch(`${GROQ_BASE}/chat/completions`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${GROQ_KEY}`,
      },
      body: JSON.stringify(req.body),
    });
    res.status(upstream.status);
    res.setHeader(
      "Content-Type",
      upstream.headers.get("content-type") || "text/event-stream"
    );
    if (!upstream.body) return res.end();
    for await (const chunk of upstream.body) res.write(chunk); // stream SSE through
    res.end();
  } catch {
    res.status(502).json({ error: "Upstream (Groq) error." });
  }
});

app.listen(PORT, () => console.log(`NOVA proxy listening on ${PORT}`));
