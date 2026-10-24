/** Test-only local HTTPS origins for the credential broker. Never used in production. */

import { createServer, type Server } from "node:https";
import type { AddressInfo } from "node:net";

// A disposable certificate for 127.0.0.1/localhost. Chromium uses an isolated
// ignoreHTTPSErrors context in credentialFixture.ts; production trust is unchanged.
const KEY = `-----BEGIN PRIVATE KEY-----
MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQCFx/qQGGg6FUwY
6JiHh84RGiFZILxkVsUxF4DUuiDptYKCyr1bsOnzHCSs6pNqqsDglWJMr2rFPGTV
DlKB+pZVA6cou2V2SBcAW1GYCOSK6ihpiaMPtCCQJ66VzLBNgFIZFWyVQAIwN+2C
qmFYsTSQ3lENT0ADXLDUJidQkIHQ2HQ5LXaolA/0+RHg47lSvCieTHbcnetdmCme
Jc3HuTsHTXDTkkQ2i0Bb7gFtC9l5m/PMhMascybfz/pSx4ReWDX2q70SlMDmB+yS
Jk5mahmcpUAkA8PxWGNE/gpCxiatE6iDWkT5BlWSu0awdDCrycmmIJnAo4UpNjOK
+AI4Ht5/AgMBAAECggEAEdW8OLOYSY4HTBbOJttbBHqoUXqEwxeySD4q5bE+rAmP
saIXpn6qYcext/+50XGcLxSbOz/ziwHnK2QyabOfkQvgoBSDjUZFEr4Z3Zvp4/8d
jhxUScaoxK8VnlDgfCSMTV3G0Qrsf8Mk/dN7ENjm+h05Tv3uucQEqvO/MAVj2RSg
6Qo9WEaTEXynrIRvqpHldg8FeDNIU495yGTM3KEp1h18Ixmlf6Y05MppIr8+011o
0xxPjydL1P18Ancl52anXAYgvhgt5/OZxfQHS0d+2up/5PKVLZZ+X8HdxDokUCZX
FoAX3QigEQF4L/wVlhduW7rqWYFCLUwI06gBOGx7OQKBgQC7X71WctSkyvTG75sk
/Ej6A74LxERUj/F4hJV6eiklI2Th7lKQOLhQQe3bkGd3+CfPnX0wDajhWEBW4oQg
qgU8n7dCgshWE2g68XltSdCdhplVGlzBvOsqlHo8e/2zS9pCmQivfiFEWaGNAoZr
Mx5udVu3WTau5iUKqRoPUTNxTQKBgQC2x1rmnniAOsFshBsg85Kt6p71LsWxcTab
TdGwDmtMrKNQNEdzQfTpKEpW4JYnPPEaaU4B718IE99sltF8pwjZrNIsrIt1KXxH
A/sp2zTkPOsMXme+qWeRSZMVWvWO03LKidsF0KxAFeyJuu4qM7HviPxCpPfRw0BU
hSKiG4Xo+wKBgCOSh4WUA17N0S67an7ZDpm4gCoHttk/Ap7YvPAlpQ4R7CMgdbg/
rG5ANgILJjmWeShnQ88NqNQvRve3xVHWNWxO/iG4ZoRA5vbZxS3EZ8CgPxfzC00U
qqjIy3QULhQOAH/IQeffUD2DrrHwmshbShm6WhEy9Li7pKijdfkWd2e5AoGBAId1
c37bDz8pTFRaC6j+G0TdTvUytrzsxKWQpMivxwHKKDa2qAVZamKpw35jb6Sg26bR
SEjS2EEqSTk3BQY23K5GEHWfYrNwDXSsFKZOmQJVy3UdOhHphqH8Pw9im/4/4yEL
zdCfeCj+lpD0grGwIjz97saNcER7Sd/Z03MEptelAoGAfdcpyYaMwTRMrVW7u2Jx
4D5TEsZv9p+ZnUIJUkratWsDlpC67HmdFAN8glKvgnzXR8M561cf/zqcpYDcQOpZ
vyVboZNdXKjeYskc0SGIecB4JbXH/3rmlECF5+iojeBhdHrEBjonRq6gFH1oXIVO
4xFILdIZr3J/Ah3liRY9pgQ=
-----END PRIVATE KEY-----`;

const CERT = `-----BEGIN CERTIFICATE-----
MIIDJTCCAg2gAwIBAgIUOeaQ3/q7f5Wp89wFoYslD1b9EoswDQYJKoZIhvcNAQEL
BQAwFDESMBAGA1UEAwwJbG9jYWxob3N0MB4XDTI2MTAyNDE1NTA1NVoXDTI2MTAy
NjE1NTA1NVowFDESMBAGA1UEAwwJbG9jYWxob3N0MIIBIjANBgkqhkiG9w0BAQEF
AAOCAQ8AMIIBCgKCAQEAhcf6kBhoOhVMGOiYh4fOERohWSC8ZFbFMReA1Log6bWC
gsq9W7Dp8xwkrOqTaqrA4JViTK9qxTxk1Q5SgfqWVQOnKLtldkgXAFtRmAjkiuoo
aYmjD7QgkCeulcywTYBSGRVslUACMDftgqphWLE0kN5RDU9AA1yw1CYnUJCB0Nh0
OS12qJQP9PkR4OO5Urwonkx23J3rXZgpniXNx7k7B01w05JENotAW+4BbQvZeZvz
zITGrHMm38/6UseEXlg19qu9EpTA5gfskiZOZmoZnKVAJAPD8VhjRP4KQsYmrROo
g1pE+QZVkrtGsHQwq8nJpiCZwKOFKTYzivgCOB7efwIDAQABo28wbTAdBgNVHQ4E
FgQUh74hx7qVpmv2tiXpw7alrJ4gWEkwHwYDVR0jBBgwFoAUh74hx7qVpmv2tiXp
w7alrJ4gWEkwDwYDVR0TAQH/BAUwAwEB/zAaBgNVHREEEzARgglsb2NhbGhvc3SH
BH8AAAEwDQYJKoZIhvcNAQELBQADggEBADDJlAQ4pZzrFVgQlvvOfQ7o4W6EieRF
/juYHv23L6bxOEcUY0exxbPgZHG5N02F3qZLSVAFZhiJz9y/5gzXSyglFd6tuHQG
mSD9mxZcEAlcRxorid56FoBJhu6DzO9NeMD+EEeq5lQjkejCB50QFw+PcDBTIoqB
VvztPexIeOruIKXzpOKFDQck7d0noQuW5N8WBlHSnX8SneyZSkyEMIqzn7VU4abV
HtbUUm5TaWd2WtQq/Bl2xOxrrkr3Eus5iibEzYXCOj5lLZO0uTRJAXkK2xHkb90y
WzrnSSibmn0/JWVymBc1quoa6FAevcc1CXVexDONIgInSbXieMSycGk=
-----END CERTIFICATE-----`;

export interface RecordedCredentialPost {
  path: string;
  body: string;
}

export interface CredentialHttpsFixture {
  origin: string;
  otherOrigin: string;
  url(path?: string): string;
  otherUrl(path?: string): string;
  posts: RecordedCredentialPost[];
  otherPosts: RecordedCredentialPost[];
  close(): Promise<void>;
}

function escapeAttribute(value: string): string {
  return value.replaceAll("&", "&amp;").replaceAll('"', "&quot;").replaceAll("<", "&lt;");
}

function form(action: string, extras = ""): string {
  return `<!doctype html><html><head><title>Credential fixture</title></head><body>
    <form id="login" method="post" action="${escapeAttribute(action)}">
      <label>User <input id="username" name="username" type="email" autocomplete="username"></label>
      <label>Password <input id="password" name="password" type="password" autocomplete="current-password"></label>
      ${extras}
      <button id="submit" type="submit">Sign in</button>
    </form>
  </body></html>`;
}

function page(path: string, query: URLSearchParams): string | null {
  const action = query.get("action") ?? "/session";
  switch (path) {
    case "/login":
      return form(action);
    case "/login-mfa":
      return form(action, '<input name="otp" type="text" autocomplete="one-time-code">');
    case "/login-captcha":
      return form(action, '<div class="g-recaptcha" data-sitekey="test-only">CAPTCHA</div>');
    case "/login-sso":
      return form(action, '<a href="/sso">Continue with SSO</a>');
    case "/login-custom":
      return `${form(action)}<script>document.querySelector("form").addEventListener("submit", () => {})</script>`;
    case "/login-iframe":
      return `${form(action)}<iframe src="/frame" title="nested"></iframe>`;
    case "/login-target":
      return form(action).replace('method="post"', 'method="post" target="_blank"');
    case "/login-get":
      return form(action).replace('method="post"', 'method="get"');
    case "/frame":
    case "/navigated":
    case "/after":
      return "<!doctype html><title>Fixture destination</title><p>destination</p>";
    default:
      return null;
  }
}

async function readBody(req: import("node:http").IncomingMessage): Promise<string> {
  const chunks: Buffer[] = [];
  for await (const chunk of req) chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk));
  return Buffer.concat(chunks).toString("utf8");
}

async function startOrigin(posts: RecordedCredentialPost[]): Promise<{ server: Server; origin: string }> {
  const server = createServer({ key: KEY, cert: CERT }, async (req, res) => {
    const url = new URL(req.url ?? "/", "https://fixture.invalid");
    if (req.method === "POST") {
      const body = await readBody(req);
      posts.push({ path: url.pathname, body });
      if (url.pathname === "/slow-session") await new Promise((resolve) => setTimeout(resolve, 250));
      if (url.pathname === "/redirect-session") {
        res.writeHead(302, { Location: "/after" });
        res.end();
        return;
      }
      res.writeHead(200, { "Content-Type": "text/plain", "Cache-Control": "no-store" });
      res.end("submission received");
      return;
    }
    const body = page(url.pathname, url.searchParams);
    res.writeHead(body === null ? 404 : 200, {
      "Content-Type": "text/html; charset=utf-8",
      "Cache-Control": "no-store",
    });
    res.end(body ?? "not found");
  });
  await new Promise<void>((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => resolve());
  });
  const address = server.address() as AddressInfo;
  return { server, origin: `https://127.0.0.1:${address.port}` };
}

export async function startCredentialHttpsFixture(): Promise<CredentialHttpsFixture> {
  const posts: RecordedCredentialPost[] = [];
  const otherPosts: RecordedCredentialPost[] = [];
  const first = await startOrigin(posts);
  try {
    const second = await startOrigin(otherPosts);
    return {
      origin: first.origin,
      otherOrigin: second.origin,
      url: (path = "/login") => `${first.origin}${path}`,
      otherUrl: (path = "/login") => `${second.origin}${path}`,
      posts,
      otherPosts,
      async close() {
        await Promise.all(
          [first.server, second.server].map(
            (server) =>
              new Promise<void>((resolve) => {
                server.closeAllConnections();
                server.close(() => resolve());
              }),
          ),
        );
      },
    };
  } catch (error) {
    first.server.closeAllConnections();
    first.server.close();
    throw error;
  }
}
