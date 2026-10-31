// The Worker: `wss://<relay>/m/<mailbox>` goes to that mailbox's Durable Object. Anything else
// is a 404. Nothing is logged.
import { Mailbox } from "./mailbox";

export { Mailbox };

export interface Env {
  MAILBOX: DurableObjectNamespace<Mailbox>;
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const match = new URL(request.url).pathname.match(/^\/m\/([0-9a-f]{32})$/);
    if (!match) return new Response(null, { status: 404 });
    if (request.headers.get("Upgrade")?.toLowerCase() !== "websocket") return new Response(null, { status: 426 });
    return env.MAILBOX.get(env.MAILBOX.idFromName(match[1])).fetch(request);
  },
} satisfies ExportedHandler<Env>;
