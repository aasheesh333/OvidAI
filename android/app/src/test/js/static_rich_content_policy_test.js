'use strict';

// Executes the production renderer's embedded policy. No Mermaid bundle or
// network is loaded. The small DOM stub is only the surface validate/show uses.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');

const kotlin = fs.readFileSync(
  'android/app/src/main/kotlin/com/dhanuk/ovidai/StaticRichContentRenderer.kt',
  'utf8',
);
const match = kotlin.match(/<script>\s*\n([\s\S]*?)<\/script><\/body><\/html>/);
assert.ok(match, 'embedded static policy script exists');

class FakeSvg {
  constructor(source) {
    this.localName = 'svg';
    this.prefix = null;
    this.style = {};
    this.textContent = (source.match(/<style>([\s\S]*?)<\/style>/) || [])[1] || '';
    this.attributes = [];
    const style = source.match(/style="([^"]*)"/);
    if (style) this.attributes.push({ name: 'style', value: style[1] });
  }
  querySelectorAll() {
    return this.textContent ? [{ localName: 'style', prefix: null, attributes: [], textContent: this.textContent }] : [];
  }
  getBBox() { return { x: 0, y: 0, width: 10, height: 10 }; }
  setAttribute() {}
}

const stage = {
  replaceChildren(node) { this.firstElementChild = node; },
};
const sandbox = {
  DOMParser: class {
    parseFromString(source) {
      const root = new FakeSvg(source);
      return {
        documentElement: root,
        querySelector() { return null; },
      };
    }
  },
  document: {
    getElementById() { return stage; },
    importNode(node) { return node; },
  },
};
sandbox.window = sandbox;
vm.runInNewContext(match[1], sandbox, { filename: 'ovid-static-policy.js' });

for (const attack of [
  '<svg><style>@keyframes move { from { opacity: 0 } to { opacity: 1 } }</style></svg>',
  '<svg><style>rect { animation: move 1s infinite; }</style></svg>',
  '<svg><rect style="transition: opacity 1s"/></svg>',
  '<svg><rect style="-webkit-animation-name: move"/></svg>',
  '<svg><style>@-webkit-keyframes move { from { opacity: 0 } }</style></svg>',
  '<svg><style>rect { animation/**/: move 1s; }</style></svg>',
  '<svg><rect style="transition/**/: opacity 1s"/></svg>',
  '<svg><style>rect { anim/**/ation: move 1s; }</style></svg>',
  '<svg><style>@key/**/frames move { from { opacity: 0 } }</style></svg>',
]) {
  assert.deepEqual(
    Array.from(sandbox.ovidShowSvg(attack)),
    [-1, -1],
    `active CSS must fail closed: ${attack}`,
  );
}
assert.deepEqual(
  Array.from(sandbox.ovidShowSvg('<svg><rect style="fill:#fff"/></svg>')),
  [10, 10],
);
assert.deepEqual(
  Array.from(sandbox.ovidShowSvg(
    '<svg><style>rect { /* animation is prose, not a declaration */ fill: #fff; }</style></svg>',
  )),
  [10, 10],
  'ordinary static CSS and comments remain usable',
);

(async () => {
  const renderedAttack = '<svg><style>rect { animation/**/: move 1s; }</style></svg>';
  const renderedStatic = '<svg><style>rect { /* harmless */ fill: #fff; }</style></svg>';
  sandbox.mermaid = {
    initialize() {},
    async parse() {},
    async render() { return { svg: renderedAttack }; },
  };
  assert.deepEqual(
    Array.from(await sandbox.ovidRenderMermaid('flowchart LR\nA --> B')),
    [-1, -1],
    'Mermaid output with comment-obfuscated motion must fail closed',
  );
  sandbox.mermaid.render = async () => ({ svg: renderedStatic });
  assert.deepEqual(
    Array.from(await sandbox.ovidRenderMermaid('flowchart LR\nA --> B')),
    [10, 10],
    'Mermaid output with ordinary static CSS remains usable',
  );
  console.log('Embedded JavaScript SVG policy attack tests passed.');
})().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
