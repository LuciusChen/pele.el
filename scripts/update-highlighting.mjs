// SPDX-License-Identifier: MIT
// Development only: generate reference spans with the unmodified website code.
// Node 22.13+ is needed for stripTypeScriptTypes; never used by the package.
import fs from 'node:fs';
import vm from 'node:vm';
import crypto from 'node:crypto';
import { stripTypeScriptTypes } from 'node:module';

const directory = 'vendor/pele-website/';
const original = fs.readFileSync(`${directory}highlight.ts`, 'utf8');
const limits = fs.readFileSync(`${directory}playground-limits.ts`, 'utf8');
const limit = Number(/maxHighlightLineLength = (\d[\d_]*)/.exec(limits)[1].replaceAll('_', ''));
const code = stripTypeScriptTypes(original)
  .replace(/^import .*playground-limits.*;\s*$/m, `const maxHighlightLineLength = ${limit};`)
  .replace(/^export\s+/gm, '');
const context = vm.createContext({});
vm.runInContext(`${code}\nglobalThis.oracle = {highlightLine, createHighlightState};`, context);
const { highlightLine, createHighlightState } = context.oracle;
const classes = [null, 'syn-punctuation', 'syn-language', 'syn-keyword', 'syn-constant',
  'syn-variable', 'syn-function', 'syn-string', 'syn-number', 'syn-yaml-key', 'syn-comment'];
const entities = { '&amp;': '&', '&lt;': '<', '&gt;': '>', '&quot;': '"', '&#39;': "'" };
const decode = value => value.replace(/&(?:amp|lt|gt|quot|#39);/g, entity => entities[entity]);
const stateBits = state => Number(state.started) | Number(state.frontmatter) << 1
  | Number(state.quote) << 2 | Number(state.meta) << 3;

function reference(source) {
  const state = createHighlightState();
  const runs = [];
  const states = [];
  let offset = 0;
  const emit = (length, kind) => {
    if (!length) return;
    offset += length;
    if (runs.at(-1)?.[1] === kind) runs.at(-1)[0] = offset;
    else runs.push([offset, kind]);
  };
  const lines = source.split('\n');
  for (const [index, line] of lines.entries()) {
    const html = highlightLine(line, 'mermaid', state);
    const stack = [];
    const colors = Array.from(line, () => 0);
    let position = 0;
    for (const match of html.matchAll(/<span class="([\w-]+)">|<\/span>|([^<]+)/g)) {
      if (match[1]) stack.push(match[1]);
      else if (match[2]) {
        const kind = classes.indexOf(stack.at(-1) ?? null);
        if (kind < 0) throw new Error(`Unknown upstream class: ${stack.at(-1)}`);
        for (const character of decode(match[2])) {
          if (position < colors.length) colors[position] = kind;
          position++;
        }
      } else stack.pop();
    }
    for (const kind of colors) emit(1, kind);
    states.push(stateBits(state));
    if (index + 1 < lines.length) emit(1, 0);
  }
  return { runs, state: stateBits(state), states };
}

const examples = [
  ['nodes-and-labels', 'flowchart LR\n开始[中文 & <标签>] --> B(("😀 é"))\nB -->|label text| C\n'],
  ['shapes', 'graph TD\nA(((one))) --> B([two]) --> C[(three)] --> D[[four]]\nE((five)) --> F{{six}} --> G[/seven/] --> H[\\eight\\]\nI[/nine\\] --> J[\\ten/] --> K>eleven]\n'],
  ['arrows', 'flowchart LR\nA---B\nA o--o B\nA x--x B\nA<==>B\nA-.->B\nA~~~B\nA -- text --> B\nA == thick ==> B\nA -. dotted .-> B\n'],
  ['comments', 'graph LR\n%% this is a comment\nA[%% label text] --> B["%% string"] %% tail\n%%{init: {"theme":"dark"}}%%\n'],
  ['frontmatter', '\n---\ntitle: Example\nconfig:\n  theme: "dark"\n  enabled: true\n  disabled: false\n  value: null\n  missing: ~\n  offset: -1.25\n  ratio: .5\n  - item: \'quoted\'\n---\nflowchart LR\nA-->B\n'],
  ['metadata', 'flowchart LR\nA@{ shape: rect, label: "first", size: -2, enabled: true } --> B\nB@{\n label: "multi\nline 😀", count: 5, disabled: false\n}\n'],
  ['styles', 'flowchart LR\nclassDef warning fill:#f00,stroke:#12345678,stroke-width:2px,color:rgb(1, 2, 3);opacity:.5\nstyle A fill:var(--my-color),font-family:"A B",stroke-dasharray: 3 4\nlinkStyle 0 stroke:#abc,stroke-width:-1.2em\nA:::warning --> B\n'],
  ['callbacks', 'flowchart LR\nclick A call callback("a")\nclick B href "https://example.com" "tooltip"\ncall handler()\n'],
  ['boundaries', 'flowchart中文 LR\nflowchart_beta LR\nxychart-betaSuffix\nA1 foo.bar a-b a--b a..b 12.3x 99x .5\n'],
  ['unicode-identifiers', 'flowchart LR\n中文_2-->á.β-Ⅳ\né-->B\nA😀-->B\n'],
  ['whitespace', '\u00a0---\ufeff\n\u2000title:\u00a0"text"\n---\nflowchart\u202fLR\nA\t-->\u3000B\n'],
  ['single-quotes', "flowchart LR\nA['one'] --> B[\"two\"]\nclick A 'unquoted'\n"],
  ['crlf-frontmatter', '---\r\ntitle: "Hello"\r\nenabled: true\r\ncount: 5\r\n---\r\nflowchart LR\r\nA-->B\r\n'],
  ['unterminated-directive-cr', 'flowchart LR\n%%{init: {"theme":"dark"}\r\nA-->B\n'],
  ['quoted-pipe-label', 'flowchart LR\nA -->|"a|b"\nC[tail]\n'],
  ['nonflow-keywords', 'sequenceDiagram\nparticipant Alice\ncritical Connect\nAlice->>Bob: hello\nend\n'],
  ['line-cap', 'flowchart LR\n' + 'A'.repeat(2000) + '\n' + 'B'.repeat(2001) + '\nC-->D\n'],
  ['utf16-line-cap', 'flowchart LR\n' + '😀'.repeat(1000) + '\n' + '😀'.repeat(1001) + '\nA-->B\n'],
  ['long-line-state', '---\n' + 'x'.repeat(2001) + '\ntitle: true\n---\nA["first\n' + 'x'.repeat(2001) + '\nlast"]\n'],
];
// Each sequence represents small edits. ERT changes only the differing span.
const edits = [
  ['multiline-quotes', ['graph LR\nA["first\nsecond"]\nB[tail]\n', 'graph LR\nA[first\nsecond"]\nB[tail]\n', 'graph LR\nA["first\nsecond"]\nB[tail]\n']],
  ['metadata-state', ['flowchart LR\nA@{\n label: "first"\n}\nB-->C\n', 'flowchart LR\nA@{\n label: "first"\n\nB-->C\n', 'flowchart LR\nA@{\n label: "first"\n}\nB-->C\n']],
  ['frontmatter-state', ['---\ntitle: Hello\n---\nflowchart LR\nA-->B\n', '--\ntitle: Hello\n---\nflowchart LR\nA-->B\n', '---\ntitle: Hello\n---\nflowchart LR\nA-->B\n']],
  ['label-contents', ['flowchart LR\nA[first] --> B["last"]\n', 'flowchart LR\nA[first %% not a comment] --> B["last"]\n', 'flowchart LR\nA[first] --> B["last"]\n']],
  ['line-limit-edit', ['graph LR\n' + 'a'.repeat(2000) + '\nB-->C\n', 'graph LR\n' + 'a'.repeat(2001) + '\nB-->C\n', 'graph LR\n' + 'a'.repeat(2000) + '\nB-->C\n']],
];
for (const [name, body] of [
  ['typing-multiline-label', 'A["first 😀\nsecond"] --> B'],
  ['typing-metadata', 'A@{\n label: "node", active: true\n} --> B'],
  ['typing-style', 'classDef good fill:#aabbcc,stroke-width:2px'],
]) {
  const characters = Array.from(body);
  edits.push([name, characters.map((_, index) => `flowchart LR\n${characters.slice(0, index + 1).join('')}\nZ[tail]\n`)]);
}
const corpus = {};
let count = 0;
for (const file of fs.readdirSync('test/corpus').filter(name => name.endsWith('-docs.json')).sort()) {
  corpus[file] = JSON.parse(fs.readFileSync(`test/corpus/${file}`, 'utf8')).map(source => {
    count++;
    return reference(source);
  });
}
const hash = value => crypto.createHash('sha256').update(value).digest('hex');
fs.writeFileSync('test/corpus/highlighting.json', JSON.stringify({
  upstream: '3a2f075ee0c3d914f0fad3545fc0f193693975ac',
  sha256: { 'highlight.ts': hash(original), 'playground-limits.ts': hash(limits) },
  maxLineLength: limit, classes, corpus,
  fixtures: examples.map(([name, source]) => ({ name, source, ...reference(source) })),
  edits: edits.map(([name, sources]) => ({ name, steps: sources.map(source => ({ source, ...reference(source) })) })),
}, null, 2) + '\n');
console.log(`${count} upstream examples, ${examples.length} focused cases, ${edits.length} edit sequences`);
