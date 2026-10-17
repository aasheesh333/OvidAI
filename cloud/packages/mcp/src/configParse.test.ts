import { describe, expect, it } from "vitest";

import {
  ConfigParseError,
  interpolateMcpValue,
  parseMcpConfig,
} from "./configParse.js";

const p = (s: string) => JSON.parse(JSON.stringify(s));

describe("interpolateMcpValue", () => {
  it("interpolates ${VAR} from env", () => {
    expect(interpolateMcpValue("Bearer ${TOKEN}", { TOKEN: "abc" })).toBe(
      "Bearer abc",
    );
  });

  it("uses ${VAR:-fallback} when unset", () => {
    expect(interpolateMcpValue("${MISSING:-fallback}", {})).toBe("fallback");
    expect(interpolateMcpValue("${VAR:-fallback}", { VAR: "set" })).toBe(
      "set",
    );
  });

  it("leaves unresolved ${VAR} literal so the credential gate can see it", () => {
    expect(interpolateMcpValue("${UNSET}", {})).toBe("${UNSET}");
    expect(interpolateMcpValue("x-${UNSET}-y", {})).toBe("x-${UNSET}-y");
  });

  it("does not interpolate malformed references", () => {
    expect(interpolateMcpValue("$NOTVAR {BRACES}", {})).toBe(
      "$NOTVAR {BRACES}",
    );
  });

  it("returns values without references untouched", () => {
    expect(interpolateMcpValue("plain", {})).toBe("plain");
  });
});

describe("parseMcpConfig — JSON", () => {
  it("parses stdio+http+sse entries from a Claude-Code .mcp.json", () => {
    const raw = p(JSON.stringify({
      mcpServers: {
        fs: {
          command: "npx",
          args: ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"],
          env: { ROOT: "/data" },
        },
        remote: {
          url: "https://mcp.example.com/mcp",
          headers: { Authorization: "Bearer t" },
        },
        events: {
          url: "https://mcp.example.com/sse",
          type: "sse",
        },
      },
    }));
    const out = parseMcpConfig(raw, { env: {} });
    expect(out).toHaveLength(3);
    const [fs, remote, events] = out;
    expect(fs.transport).toBe("stdio");
    expect(fs.command).toBe("npx");
    expect(fs.args).toEqual([
      "-y",
      "@modelcontextprotocol/server-filesystem",
      "/tmp",
    ]);
    expect(fs.env).toEqual({ ROOT: "/data" });
    expect(remote.transport).toBe("http");
    expect(remote.url).toBe("https://mcp.example.com/mcp");
    expect(remote.headers).toEqual({ Authorization: "Bearer t" });
    expect(events.transport).toBe("sse");
    expect(events.url).toBe("https://mcp.example.com/sse");
  });

  it("accepts mcp_servers and servers aliases", () => {
    for (const key of ["mcp_servers", "servers"]) {
      const out = parseMcpConfig(
        p(JSON.stringify({ [key]: { a: { command: "run" } } })),
        { env: {} },
      );
      expect(out).toHaveLength(1);
      expect(out[0]?.name).toBe("a");
      expect(out[0]?.transport).toBe("stdio");
    }
  });

  it("rejects two different top-level wrapper keys", () => {
    const raw = p(
      '{"mcpServers": {"a": {"command": "x"}}, "servers": {"b": {"url": "https://e"}}}',
    );
    expect(() => parseMcpConfig(raw, { env: {} })).toThrow(ConfigParseError);
  });

  it("rejects an entry with neither command nor url", () => {
    const raw = p(
      JSON.stringify({ mcpServers: { broken: { args: ["--flag"] } } }),
    );
    expect(() => parseMcpConfig(raw, { env: {} })).toThrow(ConfigParseError);
  });

  it("rejects a map with no recognized wrapper key", () => {
    const raw = p(JSON.stringify({ inputs: [{ id: "X" }] }));
    expect(() => parseMcpConfig(raw, { env: {} })).toThrow(ConfigParseError);
  });

  it("returns [] for an empty server map", () => {
    expect(parseMcpConfig(p('{"mcpServers": {}}'), { env: {} })).toEqual([]);
    expect(parseMcpConfig(p("{}"), { env: {} })).toEqual([]);
  });

  it("interpolates ${VAR} across url/command/args/env/headers/cwd", () => {
    const raw = p(JSON.stringify({
      mcpServers: {
        s: {
          command: "${BIN}",
          args: ["--root", "${ROOT}"],
          cwd: "${HOME}/sub",
          env: { KEY: "${API_KEY}", KEEP: "static" },
        },
        h: {
          url: "https://${HOST}/mcp",
          headers: { Authorization: "Bearer ${TOKEN}" },
        },
      },
    }));
    const out = parseMcpConfig(raw, {
      env: {
        BIN: "/usr/local/bin/serve",
        ROOT: "/data",
        HOME: "/root",
        API_KEY: "sekret-value",
        HOST: "mcp.example.com",
        TOKEN: "tok",
      },
    });
    expect(out).toHaveLength(2);
    const [s, h] = out;
    expect(s?.command).toBe("/usr/local/bin/serve");
    expect(s?.args).toEqual(["--root", "/data"]);
    expect(s?.cwd).toBe("/root/sub");
    expect(s?.env).toEqual({ KEY: "sekret-value", KEEP: "static" });
    expect(h?.url).toBe("https://mcp.example.com/mcp");
    expect(h?.headers).toEqual({ Authorization: "Bearer tok" });
  });

  it("leaves unresolved ${VAR} literal (credential gate must still see it)", () => {
    const raw = p(
      JSON.stringify({
        mcpServers: { s: { command: "npx", env: { K: "${NOPE}" } } },
      }),
    );
    const out = parseMcpConfig(raw, { env: {} });
    expect(out[0]?.env?.K).toBe("${NOPE}");
  });

  it("uses ${VAR:-default} fallbacks when the variable is unset", () => {
    const raw = p(JSON.stringify({
      mcpServers: {
        s: {
          command: "npx",
          args: ["--port", "${PORT:-8080}"],
          env: { MODE: "${MODE:-dev}" },
        },
      },
    }));
    const out = parseMcpConfig(raw, { env: { MODE: "prod" } });
    expect(out[0]?.args).toEqual(["--port", "8080"]);
    expect(out[0]?.env).toEqual({ MODE: "prod" });
    const out2 = parseMcpConfig(raw, { env: {} });
    expect(out2[0]?.env).toEqual({ MODE: "dev" });
  });

  it("shell-splits string-form args respecting quotes", () => {
    const raw = p(JSON.stringify({
      mcpServers: {
        s: { command: "npx", args: '-y --label "two words" \'single piece\'' },
      },
    }));
    const out = parseMcpConfig(raw, { env: {} });
    expect(out[0]?.args).toEqual([
      "-y",
      "--label",
      "two words",
      "single piece",
    ]);
  });

  it("parses the oauth block (snake_case + scopes)", () => {
    const raw = p(JSON.stringify({
      mcpServers: {
        s: {
          url: "https://mcp.example.com/mcp",
          oauth: {
            authorization_url: "https://id.example.com/authorize",
            token_url: "https://id.example.com/token",
            client_id: "cid",
            scopes: ["read", "write"],
            redirect_uri: "https://app.example.com/callback",
          },
        },
      },
    }));
    const out = parseMcpConfig(raw, { env: {} });
    expect(out[0]?.oauth).toEqual({
      authorizationUrl: "https://id.example.com/authorize",
      tokenUrl: "https://id.example.com/token",
      clientId: "cid",
      scopes: ["read", "write"],
      redirectUri: "https://app.example.com/callback",
    });
  });

  it("interpolates oauth values and accepts space/comma-separated scopes", () => {
    const raw = p(JSON.stringify({
      mcpServers: {
        s: {
          url: "https://mcp.example.com/mcp",
          oauth: {
            authorization_url: "https://${ID_HOST}/authorize",
            client_id: "${CLIENT_ID}",
            scopes: "read, write",
          },
        },
      },
    }));
    const out = parseMcpConfig(raw, {
      env: { ID_HOST: "id.example.com", CLIENT_ID: "cid-123" },
    });
    expect(out[0]?.oauth).toEqual({
      authorizationUrl: "https://id.example.com/authorize",
      clientId: "cid-123",
      scopes: ["read", "write"],
    });
  });

  it("rejects duplicate JSON keys", () => {
    const raw =
      '{"mcpServers": {"a": {"command": "x", "command": "y"}}}';
    expect(() => parseMcpConfig(raw, { env: {} })).toThrow(ConfigParseError);
  });

  it("normalizes streamable-http spellings to http", () => {
    const raw = p(
      JSON.stringify({
        mcpServers: { s: { url: "https://e/mcp", type: "streamable-http" } },
      }),
    );
    const out = parseMcpConfig(raw, { env: {} });
    expect(out[0]?.transport).toBe("http");
  });
});

describe("parseMcpConfig — TOML (Codex config.toml)", () => {
  it("parses [mcp_servers.x] with command/args/env.X/headers.X", () => {
    const raw = `
[mcp_servers.docs]
command = "npx"
args = ["-y", "@mcp/docs", "--root", "/wiki"]
env.ROOT = "/data"
headers."X-Token" = "tok"

[mcp_servers.remote]
url = "https://mcp.example.com/mcp"
type = "streamable-http"
headers.Authorization = "Bearer t"
`;
    const out = parseMcpConfig(raw, { env: {} });
    expect(out).toHaveLength(2);
    const [docs, remote] = out;
    expect(docs?.name).toBe("docs");
    expect(docs?.transport).toBe("stdio");
    expect(docs?.command).toBe("npx");
    expect(docs?.args).toEqual(["-y", "@mcp/docs", "--root", "/wiki"]);
    expect(docs?.env).toEqual({ ROOT: "/data" });
    expect(remote?.transport).toBe("http");
    expect(remote?.url).toBe("https://mcp.example.com/mcp");
    expect(remote?.headers?.Authorization).toBe("Bearer t");
  });

  it("supports [mcp_servers.x.env] sub-tables and multiline arrays", () => {
    const raw = `
[mcp_servers.s]
command = "serve"
args = [
  "-y",
  "pkg",
]

[mcp_servers.s.env]
KEY = "value"
`;
    const out = parseMcpConfig(raw, { env: {} });
    expect(out).toHaveLength(1);
    expect(out[0]?.command).toBe("serve");
    expect(out[0]?.args).toEqual(["-y", "pkg"]);
    expect(out[0]?.env).toEqual({ KEY: "value" });
  });

  it("parses string-form args via shell splitting", () => {
    const raw = `
[mcp_servers.s]
command = "serve"
args = '-y --label "two words"'
`;
    const out = parseMcpConfig(raw, { env: {} });
    expect(out[0]?.args).toEqual(["-y", "--label", "two words"]);
  });

  it("interpolates ${VAR} in TOML values", () => {
    const raw = `
[mcp_servers.s]
command = "serve"
url = "https://\${HOST}/mcp"
env.KEY = "\${TOML_KEY}"
`;
    const out = parseMcpConfig(raw, {
      env: { HOST: "mcp.example.com", TOML_KEY: "sekret-value" },
    });
    expect(out[0]?.env).toEqual({ KEY: "sekret-value" });
    const out2 = parseMcpConfig(raw, { env: { HOST: "mcp.example.com" } });
    expect(out2[0]?.env).toEqual({ KEY: "${TOML_KEY}" });
  });

  it("rejects duplicate sections", () => {
    const raw = `
[mcp_servers.s]
command = "a"

[mcp_servers.s]
command = "b"
`;
    expect(() => parseMcpConfig(raw, { env: {} })).toThrow(ConfigParseError);
  });

  it("rejects duplicate keys within a section", () => {
    const raw = `
[mcp_servers.s]
command = "a"
command = "b"
`;
    expect(() => parseMcpConfig(raw, { env: {} })).toThrow(ConfigParseError);
  });

  it("rejects an entry with neither command nor url", () => {
    const raw = `
[mcp_servers.s]
args = ["-y"]
`;
    expect(() => parseMcpConfig(raw, { env: {} })).toThrow(ConfigParseError);
  });
});

describe("parseMcpConfig — dispatch", () => {
  it("rejects garbage input with ConfigParseError", () => {
    expect(() => parseMcpConfig("this is not a config", { env: {} })).toThrow(
      ConfigParseError,
    );
    expect(() => parseMcpConfig("{invalid json", { env: {} })).toThrow(
      ConfigParseError,
    );
    expect(() => parseMcpConfig(p('["just", "strings"]'), { env: {} })).not.toThrow();
  });

  it("returns [] for empty and whitespace input", () => {
    expect(parseMcpConfig("", { env: {} })).toEqual([]);
    expect(parseMcpConfig("   \n  ", { env: {} })).toEqual([]);
  });

  it("treats input starting with [ as TOML when it is not JSON", () => {
    const raw = `
[mcp_servers.s]
command = "x"
`;
    const out = parseMcpConfig(raw, { env: {} });
    expect(out).toHaveLength(1);
    expect(out[0]?.command).toBe("x");
  });
});
