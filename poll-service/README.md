# Lantern feedback service

Server component for the GitHub Pages Lantern VNC website. Built with the Sites Vinext starter; D1 stores anonymous events, one poll response per browser identifier, and private feedback. The Mac viewer does not call this service.

- Public POST endpoints: `/api/events`, `/api/poll`, `/api/feedback`. No account or payment.
- Owner-only: `/admin`, `/api/stats`, `/api/inbox`, and dashboard assets. Sites authenticates the owner through Sign in with ChatGPT. `ADMIN_EMAIL` is a server-side Sites secret, never a client key. The origin must be public for anonymous form submissions; the owner routes remain protected individually.
- Events: hashed random browser UUID, event UUID, event type, allowlisted page path, referrer hostname or sanitized UTM source, campaign label, approximate country (when available), UTC timestamp. Raw IPs, full referrers/query strings, device fingerprints, and cookies are not stored by this code. Hosting providers still process network requests.
- Events expire after 90 days on subsequent writes; the dashboard queries only the last 90 days. Poll responses replace the previous browser response. Explicit messages are retained for the owner to review. Browser opt-outs affect automatic events; explicit submissions remain available.
- `/api/stats` exposes no message text or browser identifiers. Feedback text is only in the owner inbox and owner-authorized database tools. There is no public message or statistics endpoint.
- Counts are approximate: blockers, privacy opt-outs, multiple browsers, cookie/storage resets, and automated traffic affect them. Downloads count link clicks, not verified installations. Anonymous write endpoints are not an anti-fraud voting system.

## Development

Use Node 24 and the supplied Sites setup/install/build helpers. Generate new schema migrations with `npm run db:generate`; do not rewrite applied migrations. Run `node --test test/api.test.mjs`, build, apply the generated migration to the local D1 database, and preview via `npm start`. `qa` data is isolated from `production`; never seed production with demonstrations.

The supported Sites workflow owns publication to project `appgprj_6aff0460d5888191a184f333b393f405`. Source is mirrored in the public Lantern repository. Keep runtime secrets, node_modules, .git, .wrangler and local identity state out of the mirror.
