import { createMessage } from "./anthropic.ts";
import { handler } from "./handler.ts";

Deno.serve((req) => handler(req, { createMessage }));
