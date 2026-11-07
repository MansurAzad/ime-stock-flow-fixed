# Deploying to Vercel

1. Push this repository to GitHub and import it in Vercel (Framework preset: **Other** — `vercel.json` already sets install/build commands).
2. In Vercel → Project → Settings → Environment Variables, add (Production + Preview):
   - `VITE_SUPABASE_URL`, `VITE_SUPABASE_PUBLISHABLE_KEY`, `VITE_SUPABASE_PROJECT_ID`
   - `SUPABASE_URL`, `SUPABASE_PUBLISHABLE_KEY`
   - `LOVABLE_API_KEY` (needed for the AI dealer-risk ranking)
   - `SUPABASE_SERVICE_ROLE_KEY` only if available to you (not exposed on Lovable Cloud; features needing it will not work without it)
3. Deploy. The build detects `VERCEL` and uses Nitro's `vercel` preset automatically (`.vercel/output`).
4. Add your Vercel domain to the backend auth redirect URLs so sign-up confirmation emails return to it.
