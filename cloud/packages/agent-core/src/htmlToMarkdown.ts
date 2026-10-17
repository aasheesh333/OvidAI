// Minimal HTML → markdown for `fetch_url` (turndown-style, no deps).
//
// Exact port of `_htmlToMarkdown` in lib/core/agent_service.dart: drops
// non-content blocks, keeps document structure the model can actually cite
// (headings as `#`, links as `[text](url)`, lists, fenced code), decodes the
// handled entities, and collapses whitespace noise. Behavioral quirks are
// deliberate parity, not bugs — e.g. script/style/noscript strips are
// case-SENSITIVE (Dart default) while every tag rewrite below is
// case-insensitive, and a link with an empty label is dropped wholesale.

export function htmlToMarkdown(html: string): string {
  let s = html;
  // Drop non-content blocks entirely (Dart's strips here are case-sensitive).
  s = s
    .replace(/<!--[\s\S]*?-->/g, "")
    .replace(/<script[\s\S]*?<\/script>/g, "")
    .replace(/<style[\s\S]*?<\/style>/g, "")
    .replace(/<noscript[\s\S]*?<\/noscript>/g, "")
    .replace(/<(nav|footer|aside)[\s\S]*?<\/\1>/gi, "");

  // Tag rewrites, in the exact Dart order; all case-insensitive.
  s = s.replace(/<h1[^>]*>([\s\S]*?)<\/h1>/gi, (_m, t) => `\n# ${t}\n`);
  s = s.replace(/<h2[^>]*>([\s\S]*?)<\/h2>/gi, (_m, t) => `\n## ${t}\n`);
  s = s.replace(/<h3[^>]*>([\s\S]*?)<\/h3>/gi, (_m, t) => `\n### ${t}\n`);
  s = s.replace(/<h[456][^>]*>([\s\S]*?)<\/h[456]>/gi, (_m, t) => `\n#### ${t}\n`);
  // Links keep their href so the model can cite the source.
  s = s.replace(/<a[^>]*href="([^"#]*)"[^>]*>([\s\S]*?)<\/a>/gi, (_m, href, text) => {
    const label = String(text ?? "").trim();
    if (label === "") return "";
    return `[${label.replaceAll("\n", " ")}](${href})`;
  });
  s = s.replace(/<img[^>]*alt="([^"]*)"[^>]*>/gi, (_m, alt) =>
    String(alt ?? "").trim() === "" ? "" : ` [image: ${alt}] `,
  );
  s = s.replace(/<img[^>]*>/gi, "");
  s = s.replace(/<(br|hr)\s*\/?>/gi, (_m, t) =>
    String(t).toLowerCase() === "hr" ? "\n\n---\n\n" : "\n",
  );
  s = s.replace(/<\/(p|div|section|article|li|tr|table|ul|ol|h1|h2|h3|h4|h5|h6)>/gi, () => "\n");
  s = s.replace(/<li[^>]*>/gi, () => "\n- ");
  s = s.replace(/<pre[^>]*>([\s\S]*?)<\/pre>/gi, (_m, t) => `\n\`\`\`\n${t}\n\`\`\`\n`);
  s = s.replace(/<(strong|b)[^>]*>([\s\S]*?)<\/\1>/gi, (_m, _tag, t) => `**${t}**`);
  s = s.replace(/<(em|i)[^>]*>([\s\S]*?)<\/\1>/gi, (_m, _tag, t) => `*${t}*`);
  s = s.replace(/<code[^>]*>([\s\S]*?)<\/code>/gi, (_m, t) => `\`${t}\``);
  s = s.replace(/<blockquote[^>]*>/gi, () => "\n> ");

  // Strip everything left (tags we don't specifically handle → a space).
  s = s.replace(/<[^>]+>/g, " ");
  const entities: Record<string, string> = {
    "&amp;": "&",
    "&lt;": "<",
    "&gt;": ">",
    "&quot;": '"',
    "&#39;": "'",
    "&apos;": "'",
    "&nbsp;": " ",
    "&mdash;": "—",
    "&ndash;": "–",
    "&hellip;": "…",
    "&copy;": "©",
    "&reg;": "®",
  };
  for (const [entity, decoded] of Object.entries(entities)) {
    s = s.split(entity).join(decoded);
  }
  s = s.replace(/&#(\d+);/g, (_m, digits) => String.fromCharCode(Number(digits)));

  // Collapse the noise: 3+ newlines → 2, runs of spaces/tabs → 1.
  s = s
    .replaceAll("\r", "")
    .replace(/\n{3,}/g, "\n\n")
    .replace(/[ \t]{2,}/g, " ")
    .trim();
  return s;
}
