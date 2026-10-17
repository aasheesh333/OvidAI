import { describe, expect, it } from "vitest";

import { htmlToMarkdown } from "./htmlToMarkdown.js";

// Parity of lib/core/agent_service.dart `htmlToMarkdownForTest` — the exported
// seam is the exact `_htmlToMarkdown` port fetch_url uses (no fixture style
// beyond the export itself).
describe("htmlToMarkdown", () => {
  it("removes script/style/noscript blocks with their content", () => {
    const out = htmlToMarkdown(
      "<html><head><style>body { color: red; }</style>" +
        "<script>alert('x')</script></head>" +
        "<body><noscript>no js</noscript><p>kept</p></body></html>",
    );
    expect(out).toBe("kept");
  });

  it("removes html comments and nav/footer/aside blocks", () => {
    const out = htmlToMarkdown(
      "<!-- a note --><p>before</p><nav>menu junk</nav>" +
        "<footer>foot junk</footer><aside>side junk</aside><p>after</p>",
    );
    // The nav/footer/aside contents vanish; the opening <p> becomes a space
    // (generic tag strip) so the exact Dart output is "before\n after".
    expect(out).toBe("before\n after");
  });

  it("renders anchors as [text](href), dropping empty-label links", () => {
    expect(htmlToMarkdown('<a href="https://ex.com/">link text</a>')).toBe(
      "[link text](https://ex.com/)",
    );
    // A label with a newline inside collapses to a space.
    expect(htmlToMarkdown('<a href="u">two\nwords</a>')).toBe("[two words](u)");
    // Empty label → the whole anchor is dropped (href lost with it).
    expect(htmlToMarkdown('<a href="u"></a>ok')).toBe("ok");
  });

  it("renders list items as markdown bullets", () => {
    expect(htmlToMarkdown("<li>one")).toBe("- one");
    expect(htmlToMarkdown("<ul><li>one</li><li>two</li></ul>")).toBe(
      "- one\n\n- two",
    );
  });

  it("decodes the handled entities, then numeric codepoints", () => {
    expect(htmlToMarkdown("&amp;&lt;&gt;&quot;&#39;&nbsp;&mdash;")).toBe(
      '&<>"\' —',
    );
  });

  it("decodes numeric entities after the named map", () => {
    expect(htmlToMarkdown("&#65;&#66;&#67;")).toBe("ABC");
  });

  it("renders headings, emphasis, code and pre blocks", () => {
    expect(htmlToMarkdown("<h1>Title</h1>")).toBe("# Title");
    expect(htmlToMarkdown("<h2>Sub</h2>")).toBe("## Sub");
    expect(htmlToMarkdown("<h3>Deeper</h3>")).toBe("### Deeper");
    expect(htmlToMarkdown("<h4>Even</h4>")).toBe("#### Even");
    expect(htmlToMarkdown("<strong>b</strong> and <em>i</em>")).toBe("**b** and *i*");
    expect(htmlToMarkdown("<code>x = 1</code>")).toBe("`x = 1`");
    expect(htmlToMarkdown("<pre>x = 1</pre>")).toBe("```\nx = 1\n```");
  });

  it("keeps image alt text and drops bare images", () => {
    expect(htmlToMarkdown('<img src="a.png" alt="A cat">')).toBe("[image: A cat]");
    expect(htmlToMarkdown('<img src="a.png">')).toBe("");
  });

  it("converts br/hr and closes block elements with newlines", () => {
    expect(htmlToMarkdown("a<br>b")).toBe("a\nb");
    expect(htmlToMarkdown("a<hr>b")).toBe("a\n\n---\n\nb");
    // Opening <p> tags strip to a space, closing ones to a newline.
    expect(htmlToMarkdown("<p>one</p><p>two</p>")).toBe("one\n two");
    expect(htmlToMarkdown("<blockquote>quote</blockquote>")).toBe("> quote");
  });

  it("strips every remaining tag to a space and collapses noise", () => {
    expect(htmlToMarkdown("<span>a</span><span>b</span>")).toBe("a b");
    expect(htmlToMarkdown("a    b")).toBe("a b");
    expect(htmlToMarkdown("a\n\n\n\nb")).toBe("a\n\nb");
    expect(htmlToMarkdown("  padded  ")).toBe("padded");
    expect(htmlToMarkdown("a\rb")).toBe("ab");
  });

  it("end-to-end: a small page keeps its citable structure", () => {
    const out = htmlToMarkdown(
      "<html><body><h1>Page</h1>" +
        '<p>See <a href="https://ex.com/doc">the doc</a>.</p>' +
        "<ul><li>alpha</li><li>beta</li></ul>" +
        "</body></html>",
    );
    expect(out).toContain("# Page");
    expect(out).toContain("[the doc](https://ex.com/doc)");
    expect(out).toContain("- alpha");
    expect(out).toContain("- beta");
  });
});
