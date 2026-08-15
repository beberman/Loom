'use strict';
//
// The JavaScript half of the JavaScript analyzer (REQ-0024).
//
// A long-lived child process: the parent writes framed requests on stdin and
// reads one line of JSON per request on stdout. One process serves a whole
// tree, which is what keeps ANALYZE-FILE's per-file interface intact while a
// per-file `node` invocation would cost ~23ms of startup 475 times over.
//
// The frame is length-prefixed rather than JSON-encoded so the parent needs no
// JSON *writer*:
//
//     <path>\n<byte-length>\n<source bytes>
//
// and the reply is a single JSON line, so the parent needs only a reader.
// Source text is never escaped in either direction.
//
// This file extracts; it does not decide. Every judgement about what a
// construct means to the graph belongs in js-analyzer.lisp -- this side's job
// is to report what the syntax says, with lines attached.

const path = require('path');
const acorn = require(path.join(__dirname, 'vendor', 'acorn', 'dist', 'acorn.js'));
const jsx = require(path.join(__dirname, 'vendor', 'acorn-jsx'));

const Parser = acorn.Parser.extend(jsx());

// ---------------------------------------------------------------------------
// Walking
// ---------------------------------------------------------------------------

// A generic walker rather than acorn-walk: acorn-walk is a separate package
// with its own release cadence, and the base visitor would need a JSX
// extension anyway. Recursing over every child node with a `type` costs one
// property scan per node and cannot fall behind the grammar.
function children(node) {
  const out = [];
  for (const key in node) {
    if (key === 'type' || key === 'loc' || key === 'start' || key === 'end') continue;
    const value = node[key];
    if (Array.isArray(value)) {
      for (const item of value) {
        if (item && typeof item.type === 'string') out.push(item);
      }
    } else if (value && typeof value.type === 'string') {
      out.push(value);
    }
  }
  return out;
}

const FUNCTION_TYPES = new Set([
  'FunctionDeclaration', 'FunctionExpression', 'ArrowFunctionExpression',
]);

// ---------------------------------------------------------------------------
// Names
// ---------------------------------------------------------------------------

// The language's own globals, which are never definitions in the tree being
// indexed and must not be recorded as calls to anything in it.
//
// This list is not tidiness. Without it `new Error(...)` records a call to
// ERROR, and a repository that happens to define a component called Error --
// front-end defines three -- collects an edge from every throw site in the
// codebase: measured at 315 inbound edges each, which made those three
// components the top three hubs in `structure` ahead of every real one. A
// fabricated edge that outranks the true answer is CON-0001's failure in the
// place it does the most damage, since hub ranking is what a reader new to a
// tree looks at first.
const GLOBAL_VALUES = new Set([
  'Array', 'ArrayBuffer', 'BigInt', 'Boolean', 'DataView', 'Date', 'Error',
  'EvalError', 'FinalizationRegistry', 'Function', 'Infinity', 'Intl', 'JSON',
  'Map', 'Math', 'NaN', 'Number', 'Object', 'Promise', 'Proxy', 'RangeError',
  'ReferenceError', 'Reflect', 'RegExp', 'Set', 'String', 'Symbol',
  'SyntaxError', 'TypeError', 'URIError', 'WeakMap', 'WeakRef', 'WeakSet',
  'console', 'decodeURI', 'decodeURIComponent', 'encodeURI',
  'encodeURIComponent', 'globalThis', 'isFinite', 'isNaN', 'parseFloat',
  'parseInt', 'undefined',
  // Host globals. A browser tree calls these constantly and none of them is
  // ever defined by the project.
  'document', 'window', 'navigator', 'localStorage', 'sessionStorage',
  'fetch', 'alert', 'confirm', 'prompt', 'setTimeout', 'clearTimeout',
  'setInterval', 'clearInterval', 'requestAnimationFrame',
  'cancelAnimationFrame', 'structuredClone', 'queueMicrotask',
  'URL', 'URLSearchParams', 'Blob', 'File', 'FileReader', 'FormData',
  'Headers', 'Request', 'Response', 'AbortController', 'Image', 'Audio',
  'process', 'Buffer', 'require', 'module', 'exports', '__dirname',
  '__filename',
]);

// The name of a callee, for :call-names. Only the parts that can resolve to a
// definition somewhere in the tree are worth recording.
//
//   foo()               -> foo
//   obj.method()        -> method   (the property; the receiver is a value)
//   obj.a.b()           -> b
//   JSON.stringify(x)   -> nothing  (the receiver is a language global)
//   Array.isArray(x)    -> nothing
//
// The receiver test is what the member case needs and the bare case does not
// explain on its own. `Array.isArray(x)` would otherwise record ISARRAY, and
// front-end defines a real isArray in src/utils/utils.js that was collecting
// every one of those: 67 inbound edges, most of them false. Dropping the
// property when the receiver is a global keeps the true calls to the local
// isArray and discards the builtin's.
//
// A computed member call -- obj[expr]() -- yields nothing, which is CON-0001:
// an unresolvable name is a recorded gap, not a guess.
function calleeName(node) {
  if (!node) return null;
  if (node.type === 'Identifier') {
    return GLOBAL_VALUES.has(node.name) ? null : node.name;
  }
  if (node.type === 'MemberExpression' && !node.computed) {
    if (node.object && node.object.type === 'Identifier'
        && GLOBAL_VALUES.has(node.object.name)) {
      return null;
    }
    return node.property && node.property.type === 'Identifier'
      ? node.property.name
      : null;
  }
  return null;
}

// The name of a JSX element: <Thing />, <Thing.Sub />, <div />.
// Lowercase single-word names are host elements (div, span) and never resolve
// to a definition, so they are dropped here rather than travelling as call
// names nothing can match.
function jsxName(node) {
  const name = node.name;
  if (!name) return null;
  if (name.type === 'JSXIdentifier') {
    return /^[a-z]/.test(name.name) ? null : name.name;
  }
  if (name.type === 'JSXMemberExpression') {
    let cursor = name;
    while (cursor.type === 'JSXMemberExpression') cursor = cursor.property;
    return cursor.type === 'JSXIdentifier' ? cursor.name : null;
  }
  return null;
}

function paramNames(params) {
  return params.map((param) => {
    switch (param.type) {
      case 'Identifier': return param.name;
      case 'RestElement': return '...' + (param.argument.name || '?');
      case 'AssignmentPattern': return (param.left && param.left.name) || '?';
      case 'ObjectPattern': return '{}';
      case 'ArrayPattern': return '[]';
      default: return '?';
    }
  });
}

// ---------------------------------------------------------------------------
// Extraction
// ---------------------------------------------------------------------------

function extract(source, ast) {
  const definitions = [];
  const imports = [];
  const exports = [];

  // Calls and JSX usages found outside any named definition -- a module-level
  // side effect, an IIFE, a call in a default export's body. They are reported
  // on the file rather than dropped.
  const fileCalls = [];
  const fileJsx = [];

  function record(kind, name, node, extra) {
    const definition = Object.assign({
      kind,
      name,
      startLine: node.loc.start.line,
      endLine: node.loc.end.line,
      calls: [],
      jsx: [],
    }, extra || {});
    definitions.push(definition);
    return definition;
  }

  // Walk BODY attributing every call and JSX usage to OWNER. Nested function
  // expressions do not get their own entity -- an inline callback is not
  // something another file can name -- so their calls belong to the enclosing
  // named definition, which is what makes `impact` on a hook reach the
  // component that uses it.
  function walkBody(node, owner) {
    const calls = owner ? owner.calls : fileCalls;
    const usages = owner ? owner.jsx : fileJsx;
    const stack = [node];
    while (stack.length) {
      const current = stack.pop();
      if (current.type === 'CallExpression' || current.type === 'NewExpression') {
        const name = calleeName(current.callee);
        if (name) calls.push(name);
      } else if (current.type === 'JSXOpeningElement') {
        const name = jsxName(current);
        if (name) usages.push(name);
      }
      for (const child of children(current)) stack.push(child);
    }
  }

  // A class body: each method is its own definition, keyed Class.method so two
  // classes with a `render` do not collide on one natural key.
  function walkClass(node, className) {
    for (const member of node.body.body) {
      if (member.type !== 'MethodDefinition' && member.type !== 'PropertyDefinition') continue;
      const key = member.key;
      const memberName = key && (key.name || key.value);
      if (!memberName) continue;
      const definition = record('method', className + '.' + memberName, member, {
        static: !!member.static,
        params: member.value && member.value.params ? paramNames(member.value.params) : [],
      });
      if (member.value) walkBody(member.value, definition);
    }
  }

  // A declarator whose initialiser is a function is a function definition:
  //   const useThing = () => {...}
  // which is how most of a modern React tree spells one. A declarator whose
  // initialiser is anything else is a module-level variable.
  function walkDeclaration(node, exported) {
    for (const declarator of node.declarations) {
      const name = declarator.id && declarator.id.name;
      if (!name) continue;
      const init = declarator.init;
      if (init && FUNCTION_TYPES.has(init.type)) {
        const definition = record('function', name, declarator, {
          exported,
          params: paramNames(init.params),
          async: !!init.async,
          arrow: init.type === 'ArrowFunctionExpression',
        });
        walkBody(init, definition);
      } else if (init && init.type === 'ClassExpression') {
        record('class', name, declarator, {
          exported,
          superclass: init.superClass ? calleeName(init.superClass) : null,
        });
        walkClass(init, name);
      } else {
        const definition = record('variable', name, declarator, {
          exported,
          kind_: node.kind,
        });
        if (init) walkBody(init, definition);
      }
    }
  }

  function walkTop(node, exported) {
    switch (node.type) {
      case 'FunctionDeclaration': {
        if (!node.id) break;
        const definition = record('function', node.id.name, node, {
          exported,
          params: paramNames(node.params),
          async: !!node.async,
          arrow: false,
        });
        walkBody(node, definition);
        break;
      }
      case 'ClassDeclaration': {
        if (!node.id) break;
        record('class', node.id.name, node, {
          exported,
          superclass: node.superClass ? calleeName(node.superClass) : null,
        });
        walkClass(node, node.id.name);
        break;
      }
      case 'VariableDeclaration':
        walkDeclaration(node, exported);
        break;
      default:
        walkBody(node, null);
    }
  }

  for (const node of ast.body) {
    switch (node.type) {
      case 'ImportDeclaration': {
        imports.push({
          source: node.source.value,
          line: node.loc.start.line,
          names: node.specifiers.map((specifier) => ({
            local: specifier.local.name,
            imported: specifier.type === 'ImportDefaultSpecifier'
              ? 'default'
              : (specifier.imported ? (specifier.imported.name || specifier.imported.value) : '*'),
          })),
        });
        break;
      }
      case 'ExportNamedDeclaration': {
        if (node.declaration) {
          walkTop(node.declaration, true);
        }
        for (const specifier of node.specifiers) {
          exports.push({
            name: specifier.exported.name || specifier.exported.value,
            local: specifier.local ? specifier.local.name : null,
            line: node.loc.start.line,
          });
        }
        if (node.source) {
          imports.push({
            source: node.source.value,
            line: node.loc.start.line,
            names: [],
            reexport: true,
          });
        }
        break;
      }
      case 'ExportAllDeclaration': {
        imports.push({
          source: node.source.value,
          line: node.loc.start.line,
          names: [],
          reexport: true,
        });
        break;
      }
      case 'ExportDefaultDeclaration': {
        // A default export has no name at the definition site (REQ-0024's
        // fourth open question). When the declaration carries one -- `export
        // default function Foo()` -- that name is used and the entity is also
        // marked as the default. When it does not, no name is invented here;
        // the Lisp side keys it on the module, which is the only stable
        // answer, and it is the analyzer's decision to make rather than this
        // script's.
        const declaration = node.declaration;
        const named = declaration
          && (declaration.type === 'FunctionDeclaration' || declaration.type === 'ClassDeclaration')
          && declaration.id;
        if (named) {
          walkTop(declaration, true);
          const last = definitions[definitions.length - 1];
          if (last) last.default = true;
        } else if (declaration) {
          exports.push({ name: 'default', local: null, line: node.loc.start.line, anonymous: true });
          const definition = record(
            FUNCTION_TYPES.has(declaration.type) ? 'function' : 'variable',
            null,
            node,
            { exported: true, default: true, anonymous: true,
              params: declaration.params ? paramNames(declaration.params) : [] }
          );
          walkBody(declaration, definition);
        }
        break;
      }
      default:
        walkTop(node, false);
    }
  }

  return { definitions, imports, exports, fileCalls, fileJsx };
}

// ---------------------------------------------------------------------------
// One request
// ---------------------------------------------------------------------------

function analyze(filePath, source) {
  const lineCount = source.length === 0 ? 0 : source.split('\n').length;
  const base = { path: filePath, lineCount };

  // JSX is enabled for every extension, .js included: the ecosystem puts JSX
  // in .js constantly and front-end is no exception, so keying the plugin to
  // the extension would fail on the majority of the tree.
  //
  // sourceType 'module' first, then 'script'. A CommonJS file with a
  // top-level `return` or a bare `with` is a parse error under module rules
  // and valid under script rules, and the reverse is not true, so trying
  // module first and falling back costs a reparse only for the files that
  // need it.
  let ast = null;
  let failure = null;
  for (const sourceType of ['module', 'script']) {
    try {
      ast = Parser.parse(source, {
        ecmaVersion: 'latest',
        sourceType,
        locations: true,
        allowHashBang: true,
        allowReturnOutsideFunction: sourceType === 'script',
        allowAwaitOutsideFunction: true,
      });
      failure = null;
      break;
    } catch (error) {
      failure = error;
    }
  }

  if (!ast) {
    // R3: a file that will not parse is still indexed, and its damage is
    // recorded with a line range. acorn stops at the first error, so the
    // range runs from the reported position to the end of the file -- that is
    // what is actually unknown, and claiming a narrower range would be a
    // fabricated fact.
    const line = (failure && failure.loc && failure.loc.line) || 1;
    return Object.assign(base, {
      definitions: [], imports: [], exports: [], fileCalls: [], fileJsx: [],
      damage: {
        message: String(failure && failure.message || 'parse failed'),
        startLine: line,
        endLine: lineCount || line,
      },
    });
  }

  return Object.assign(base, extract(source, ast));
}

// ---------------------------------------------------------------------------
// The frame loop
// ---------------------------------------------------------------------------

let buffer = Buffer.alloc(0);

// Frames are consumed from a byte buffer rather than a decoded string: the
// length in the header counts bytes, and a source file with any non-ASCII in
// it makes those two different numbers.
function pump() {
  for (;;) {
    const firstBreak = buffer.indexOf(0x0a);
    if (firstBreak < 0) return;
    const secondBreak = buffer.indexOf(0x0a, firstBreak + 1);
    if (secondBreak < 0) return;

    const filePath = buffer.slice(0, firstBreak).toString('utf8');
    const length = parseInt(buffer.slice(firstBreak + 1, secondBreak).toString('utf8'), 10);
    if (!Number.isFinite(length) || length < 0) {
      process.stdout.write(JSON.stringify({
        path: filePath, error: 'malformed frame header',
      }) + '\n');
      buffer = buffer.slice(secondBreak + 1);
      continue;
    }

    const bodyStart = secondBreak + 1;
    if (buffer.length < bodyStart + length) return;

    const source = buffer.slice(bodyStart, bodyStart + length).toString('utf8');
    buffer = buffer.slice(bodyStart + length);

    let reply;
    try {
      reply = analyze(filePath, source);
    } catch (error) {
      // An extractor bug costs one file and reports itself. It must never take
      // the process down, because the process is serving a whole tree.
      reply = { path: filePath, lineCount: 0, definitions: [], imports: [],
                exports: [], fileCalls: [], fileJsx: [],
                error: String(error && error.stack || error) };
    }
    process.stdout.write(JSON.stringify(reply) + '\n');
  }
}

process.stdin.on('data', (chunk) => {
  buffer = Buffer.concat([buffer, chunk]);
  pump();
});
process.stdin.on('end', () => process.exit(0));
