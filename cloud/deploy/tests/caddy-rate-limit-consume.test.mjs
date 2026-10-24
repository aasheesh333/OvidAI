import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { createHmac, randomUUID, timingSafeEqual } from "node:crypto";
import { mkdtemp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { after, before, beforeEach, describe, test } from "node:test";

const TEST_SECRET = "task9-caddy-local-test-secret-at-least-32-bytes";
const CONSUME_PATH = "/internal/rate-limits/consume";
const CADDY_IMAGE = "caddy:2-alpine";
const REPO_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../../..");
const SNIPPET_PATH = join(REPO_ROOT, "cloud/deploy/caddy-snippet.conf");
const snippet = await readFile(SNIPPET_PATH, "utf8");

function withoutComments(source) {
  return source.split(/\r?\n/).map((line) => {
    let quote = "";
    let escaped = false;
    for (let index = 0; index < line.length; index += 1) {
      const char = line[index];
      if (escaped) {
        escaped = false;
      } else if (char === "\\" && quote) {
        escaped = true;
      } else if ((char === '"' || char === "`") && (!quote || quote === char)) {
        quote = quote ? "" : char;
      } else if (char === "#" && !quote) {
        return line.slice(0, index);
      }
    }
    return line;
  });
}

function blocks(source, header) {
  const lines = withoutComments(source);
  const found = [];
  for (let start = 0; start < lines.length; start += 1) {
    if (lines[start].trim() !== `${header} {`) continue;
    let depth = 0;
    for (let end = start; end < lines.length; end += 1) {
      for (const char of lines[end]) {
        if (char === "{") depth += 1;
        if (char === "}") depth -= 1;
      }
      if (depth === 0) {
        found.push(lines.slice(start + 1, end));
        start = end;
        break;
      }
    }
  }
  return found;
}

function normalized(block) {
  return block.map((line) => line.trim()).filter(Boolean);
}

test("static: the consume matcher is exact, POST-only, and the only internal route", () => {
  const matcher = blocks(snippet, "@ovidRateLimitConsume");
  assert.equal(matcher.length, 1, "missing or duplicate @ovidRateLimitConsume matcher");
  assert.deepEqual(normalized(matcher[0]), [
    "method POST",
    `path ${CONSUME_PATH}`,
  ]);

  const internalDirectives = withoutComments(snippet)
    .map((line) => line.trim())
    .filter((line) => line.includes("/internal"));
  assert.deepEqual(internalDirectives, [`path ${CONSUME_PATH}`]);
});

test("static: consume transport preserves the path and pins gateway/client-IP forwarding", () => {
  const route = blocks(snippet, "handle @ovidRateLimitConsume");
  assert.equal(route.length, 1, "missing or duplicate consume handle");
  assert.deepEqual(normalized(route[0]), [
    "reverse_proxy 127.0.0.1:8082 {",
    "header_up X-Forwarded-For {client_ip}",
    "}",
  ]);
});

test("static: the existing cloud route remains intact", () => {
  const cloud = blocks(snippet, "handle /cloud/*");
  assert.equal(cloud.length, 1);
  assert.deepEqual(normalized(cloud[0]), [
    "request_body {",
    "max_size 20MB",
    "}",
    "reverse_proxy 127.0.0.1:8082 {",
    "header_up X-Forwarded-For {client_ip}",
    "}",
  ]);
});

function detectCaddy() {
  const direct = spawnSync("caddy", ["version"], {
    encoding: "utf8",
    stdio: "ignore",
    timeout: 5_000,
  });
  if (!direct.error && direct.status === 0) return { kind: "direct" };

  const docker = spawnSync("docker", ["image", "inspect", CADDY_IMAGE], {
    encoding: "utf8",
    stdio: "ignore",
    timeout: 5_000,
  });
  if (!docker.error && docker.status === 0) {
    return { kind: "docker", image: CADDY_IMAGE };
  }
  return null;
}

const caddy = detectCaddy();
const localDescribe = caddy ? describe : (name, body) => describe(name, { skip: "BLOCKED: no local Caddy binary or image" }, body);

localDescribe("disposable loopback Caddy routes", () => {
  let temporaryDirectory;
  let upstream;
  let upstreamPort;
  let caddyPort;
  let caddyChild;
  let caddyExited;
  let caddyContainerName;
  let caddyOutput = "";
  const requests = [];

  async function listen(server, port = 0) {
    await new Promise((resolveListen, reject) => {
      server.once("error", reject);
      server.listen(port, "127.0.0.1", resolveListen);
    });
    return server.address().port;
  }

  async function close(server) {
    if (!server.listening) return;
    await new Promise((resolveClose, reject) => {
      server.close((error) => error ? reject(error) : resolveClose());
    });
  }

  async function reservePort() {
    const reservation = createServer();
    const port = await listen(reservation);
    await close(reservation);
    return port;
  }

  function signature(method, path, timestamp, body) {
    return createHmac("sha256", TEST_SECRET)
      .update(`${method}\n${path}\n${timestamp}\n${body}`)
      .digest("hex");
  }

  function signedConsumeRequest() {
    const timestamp = String(Math.floor(Date.now() / 1000));
    const body = JSON.stringify({
      class: "send",
      ip: "203.0.113.88",
      requestId: "caddy-local-signed-transport",
    });
    return {
      body,
      headers: {
        "content-type": "application/json",
        "x-forwarded-for": "198.51.100.200",
        "x-ovid-timestamp": timestamp,
        "x-ovid-signature": signature("POST", CONSUME_PATH, timestamp, body),
      },
    };
  }

  before(async () => {
    temporaryDirectory = await mkdtemp(join(tmpdir(), "ovid-task9-caddy-test-"));
    const dataDirectory = join(temporaryDirectory, "data");
    const configDirectory = join(temporaryDirectory, "config");
    await mkdir(dataDirectory);
    await mkdir(configDirectory);

    upstream = createServer(async (request, response) => {
      let body = "";
      for await (const chunk of request) body += chunk;
      requests.push({
        method: request.method,
        url: request.url,
        forwardedFor: request.headers["x-forwarded-for"],
        body,
      });

      if (request.url?.startsWith("/cloud/")) {
        response.writeHead(200, { "content-type": "application/json" });
        response.end(JSON.stringify({ ok: true }));
        return;
      }

      if (request.method === "POST" && request.url === CONSUME_PATH) {
        const timestamp = request.headers["x-ovid-timestamp"];
        const supplied = request.headers["x-ovid-signature"];
        const fresh = typeof timestamp === "string" &&
          /^\d+$/.test(timestamp) &&
          Math.abs(Math.floor(Date.now() / 1000) - Number(timestamp)) <= 60;
        let authenticated = fresh && typeof supplied === "string" && /^[a-f0-9]{64}$/.test(supplied);
        if (authenticated) {
          const expected = Buffer.from(signature("POST", CONSUME_PATH, timestamp, body), "hex");
          authenticated = timingSafeEqual(expected, Buffer.from(supplied, "hex"));
        }
        if (!authenticated) {
          response.writeHead(401, { "content-type": "application/json" });
          response.end(JSON.stringify({ error: "unauthorized" }));
          return;
        }
        response.writeHead(200, { "content-type": "application/json" });
        response.end(JSON.stringify({ allowed: true, retryAfterSeconds: 0, scope: "uid+ip" }));
        return;
      }

      response.writeHead(418, { "content-type": "text/plain" });
      response.end("unexpected upstream bypass");
    });
    upstreamPort = await listen(upstream);
    caddyPort = await reservePort();

    const localSnippet = snippet.replaceAll("127.0.0.1:8082", `127.0.0.1:${upstreamPort}`);
    const caddyfile = join(temporaryDirectory, "Caddyfile");
    await writeFile(caddyfile, `{
	admin off
	auto_https off
}
http://127.0.0.1:${caddyPort} {
	bind 127.0.0.1
${localSnippet}
	handle {
		respond "Not found" 404
	}
}
`);

    let command;
    let args;
    if (caddy.kind === "direct") {
      command = "caddy";
      args = ["run", "--config", caddyfile, "--adapter", "caddyfile"];
    } else {
      command = "docker";
      caddyContainerName = `ovid-task9-caddy-${process.pid}-${randomUUID().slice(0, 8)}`;
      args = [
        "run", "--rm", "--pull", "never", "--network", "host",
        "--name", caddyContainerName,
        "-v", `${caddyfile}:/etc/caddy/Caddyfile:ro`,
        "-v", `${dataDirectory}:/data`,
        "-v", `${configDirectory}:/config`,
        caddy.image,
        "caddy", "run", "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile",
      ];
    }
    caddyChild = spawn(command, args, { stdio: ["ignore", "pipe", "pipe"] });
    caddyExited = new Promise((resolveExit) => caddyChild.once("exit", resolveExit));
    caddyChild.stdout.on("data", (chunk) => { caddyOutput += chunk; });
    caddyChild.stderr.on("data", (chunk) => { caddyOutput += chunk; });
    caddyChild.once("error", (error) => { caddyOutput += `\n${error.stack ?? error}`; });

    const deadline = Date.now() + 15_000;
    for (;;) {
      if (caddyChild.exitCode !== null || caddyOutput.includes("Error:")) {
        throw new Error(`disposable Caddy exited before readiness:\n${caddyOutput}`);
      }
      try {
        const response = await fetch(`http://127.0.0.1:${caddyPort}/task9-readiness`);
        if (response.status === 404) break;
      } catch {
        // The listener is not ready yet.
      }
      if (Date.now() >= deadline) {
        throw new Error(`disposable Caddy readiness timed out:\n${caddyOutput}`);
      }
      await new Promise((resolveWait) => setTimeout(resolveWait, 50));
    }
  });

  beforeEach(() => {
    requests.length = 0;
  });

  after(async () => {
    if (caddyChild && caddyChild.exitCode === null && caddyChild.signalCode === null) {
      if (caddyContainerName) {
        spawnSync("docker", ["stop", "--time", "2", caddyContainerName], {
          stdio: "ignore",
          timeout: 10_000,
        });
      } else {
        caddyChild.kill("SIGTERM");
      }
    }
    if (caddyExited) {
      await Promise.race([
        caddyExited,
        new Promise((resolveWait) => setTimeout(resolveWait, 5_000)),
      ]);
    }
    if (upstream) await close(upstream);
    if (temporaryDirectory) await rm(temporaryDirectory, { recursive: true, force: true });
  });

  test("signed POST reaches upstream transport with its path intact and client XFF replaced", async () => {
    const signed = signedConsumeRequest();
    const response = await fetch(`http://127.0.0.1:${caddyPort}${CONSUME_PATH}`, {
      method: "POST",
      headers: signed.headers,
      body: signed.body,
    });
    assert.equal(response.status, 200);
    assert.deepEqual(await response.json(), { allowed: true, retryAfterSeconds: 0, scope: "uid+ip" });
    assert.equal(requests.length, 1);
    assert.deepEqual(requests[0], {
      method: "POST",
      url: CONSUME_PATH,
      forwardedFor: "127.0.0.1",
      body: signed.body,
    });
  });

  test("missing and forged signatures reach the upstream HMAC boundary and return 401", async () => {
    for (const headers of [
      { "content-type": "application/json" },
      {
        "content-type": "application/json",
        "x-ovid-timestamp": String(Math.floor(Date.now() / 1000)),
        "x-ovid-signature": "00",
      },
    ]) {
      const response = await fetch(`http://127.0.0.1:${caddyPort}${CONSUME_PATH}`, {
        method: "POST",
        headers,
        body: JSON.stringify({ class: "send", ip: "203.0.113.88" }),
      });
      assert.equal(response.status, 401);
      assert.deepEqual(await response.json(), { error: "unauthorized" });
      assert.equal(response.headers.get("content-type"), "application/json");
    }
    assert.equal(requests.length, 2, "Caddy must not replace gateway HMAC with an edge allow or 404");
  });

  test("wrong methods and other internal paths are 404 with no upstream bypass", async () => {
    for (const method of ["GET", "HEAD", "PUT", "PATCH", "DELETE", "OPTIONS"]) {
      const response = await fetch(`http://127.0.0.1:${caddyPort}${CONSUME_PATH}`, { method });
      assert.equal(response.status, 404, `${method} ${CONSUME_PATH}`);
    }
    for (const path of [
      "/internal/rate-limits/consume/",
      "/internal/rate-limits/consume/extra",
      "/internal/rate-limits",
      "/internal/other",
    ]) {
      const response = await fetch(`http://127.0.0.1:${caddyPort}${path}`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: "{}",
      });
      assert.equal(response.status, 404, `POST ${path}`);
    }
    assert.equal(requests.length, 0);
  });

  test("the pre-existing cloud route still proxies", async () => {
    const response = await fetch(`http://127.0.0.1:${caddyPort}/cloud/v1/health`);
    assert.equal(response.status, 200);
    assert.deepEqual(await response.json(), { ok: true });
    assert.equal(requests.length, 1);
    assert.equal(requests[0].url, "/cloud/v1/health");
  });
});
