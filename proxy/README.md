# ClassNotes NOVA proxy

A tiny service that holds the Groq API key **server-side** so it never ships in
the app. The app sends its ClassMate session token; the proxy validates it
against ClassMate's `/auth/me` and forwards the streaming `chat/completions`
call to Groq with the real key. This both hides the key and gates usage to
signed-in ClassNotes users (so nobody else burns the free Groq quota).

## Deploy to Railway (free)

```bash
cd proxy
railway init            # create a new project (or `railway link` an existing one)
railway variables --set GROQ_API_KEY=gsk_your_FRESH_key
railway up              # build + deploy
railway domain          # generate a public URL
```

Env vars:
| var | value |
|---|---|
| `GROQ_API_KEY` | a **fresh** Groq key (rotate the old one at console.groq.com) |
| `CM_API_BASE_URL` | (optional) ClassMate API base; defaults to prod |
| `GROQ_BASE_URL` | (optional) defaults to `https://api.groq.com/openai/v1` |

## Point the app at it

Once you have the public URL (e.g. `https://classnotes-nova-proxy.up.railway.app`):

1. In `Config/Info.plist`, set `SUPPORT_AI_BASE_URL` to `<url>/openai/v1` and
   `SUPPORT_AI_MODE` to `proxy`, and remove the `GROQ_API_KEY` /
   `SUPPORT_AI_API_KEY` entries (so no key is baked into the binary).
2. In proxy mode the app sends the ClassMate session token as the bearer
   instead of a Groq key.

(That app wiring is a one-commit change once the proxy URL exists.)
