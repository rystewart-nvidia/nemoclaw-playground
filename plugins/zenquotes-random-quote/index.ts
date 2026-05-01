import { definePluginEntry } from "openclaw/plugin-sdk/plugin-entry";

const ZENQUOTES_RANDOM_ENDPOINT = "https://zenquotes.io/api/random";

const emptyParameters = {
  type: "object",
  additionalProperties: false,
  properties: {},
} as const;

function cleanString(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : null;
}

export default definePluginEntry({
  id: "zenquotes",
  name: "ZenQuotes",
  description: "Adds a tool for fetching a random quote from ZenQuotes.",
  register(api) {
    api.registerTool({
      name: "zenquotes_random_quote",
      description: "Fetch a random quote from ZenQuotes and return the quote with its author.",
      parameters: emptyParameters,
      async execute() {
        const response = await fetch(ZENQUOTES_RANDOM_ENDPOINT, {
          headers: {
            accept: "application/json",
            "user-agent": "openclaw-zenquotes-plugin/0.1.0",
          },
          signal: AbortSignal.timeout(10000),
        });

        if (!response.ok) {
          throw new Error(`ZenQuotes request failed with HTTP ${response.status}`);
        }

        const payload = await response.json();
        if (!Array.isArray(payload) || payload.length === 0) {
          throw new Error("ZenQuotes returned an unexpected response shape");
        }

        const quote = payload[0] as Record<string, unknown>;
        const text = cleanString(quote.q);
        const author = cleanString(quote.a) ?? "Unknown";
        if (!text) {
          throw new Error("ZenQuotes response did not include a quote");
        }

        return {
          content: [
            {
              type: "text",
              text: `"${text}" - ${author}`,
            },
          ],
        };
      },
    });
  },
});
