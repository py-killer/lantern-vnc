import { handleApi, isOwner } from "../service/api.mjs";
import handler from "vinext/server/fetch-handler";
import { runWithConnectorBinding } from "../lib/connector-context";
import type { ConnectorBinding } from "../lib/connector-contract.mjs";

import adminHTML from '../owner/index.html?raw';
import adminJS from '../owner/stats.js?raw';
import adminCSS from '../owner/styles.css?raw';
function ownerAsset(path: string) {
  const asset = path === '/admin' ? [adminHTML,'text/html'] : path === '/owner-assets/stats.js' ? [adminJS,'text/javascript'] : path === '/owner-assets/styles.css' ? [adminCSS,'text/css'] : null;
  return asset ? new Response(asset[0],{headers:{'Content-Type':asset[1]+'; charset=utf-8','Cache-Control':'no-store','X-Content-Type-Options':'nosniff','Referrer-Policy':'no-referrer'}}) : new Response('Not found',{status:404});
}
const worker = {
  fetch(request: Request, env: Cloudflare.Env, ctx: ExecutionContext<{ CONNECTORS?: ConnectorBinding }>) {
    const url = new URL(request.url);
    if (url.pathname.startsWith('/api/')) return handleApi(request, env);
    if (url.pathname === '/admin' || url.pathname.startsWith('/owner-assets/')) {
      if (!isOwner(request, env)) {
        if (!request.headers.get('oai-authenticated-user-email')) return Response.redirect(url.origin + '/signin-with-chatgpt?return_to=%2Fadmin',302);
        return new Response('This dashboard is available to the site owner only.',{status:403});
      }
      return ownerAsset(url.pathname);
    }
    let binding = ctx.props?.CONNECTORS;
    // Local preview emulates the same request-scoped capability. This branch and
    // the auxiliary service binding are absent from production builds.
    if (import.meta.env.DEV && !binding && env.CONNECTORS) {
      const preview = env.CONNECTORS;
      const expiresAt = Date.now() + 60_000;
      binding = {
        async getContext() {
          if (Date.now() >= expiresAt) return { status: "request_context_expired" };
          return preview.getContext?.() ?? { status: "binding_unavailable" };
        },
        async invoke(connectorId, actionName, args) {
          if (Date.now() >= expiresAt) {
            return { status: "request_context_expired", message: "This request has expired. Please try again." };
          }
          return preview.invoke(connectorId, actionName, args);
        },
      };
    }
    return runWithConnectorBinding(binding, () => handler.fetch(request, env, ctx));
  },
};

export default worker;
