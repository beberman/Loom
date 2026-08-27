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

// A string literal argument that looks like a path, with the callee that
// received it and the position it sat in.
//
// DES-0025 D1 splits the work here rather than teaching this process what a
// route is: the extractor reports path-shaped literals, and the Lisp side
// decides which callees publish routes using the repository's own
// .loom/frameworks.yaml. Nothing about easy-routes, this codebase's `sendGet',
// or any other convention belongs in a JavaScript parser.
//
// Path-shaped is a wire-size bound, not a semantic claim. Every string literal
// argument in a tree is a great many of them -- front-end logs constantly --
// and almost none can be a route. A literal with a `/' and no whitespace is
// the cheap test that keeps `logger.debug("server: making fetch request to ")'
// off the wire while keeping "public/game/create" on it. A route with a space
// in it would be missed and is not a thing.
//
// A template literal is deliberately not reported. `${TILE_PROXY_BASE}${ep}'
// is a route computed at runtime, and recording its static fragments as a
// claim would invent a join the source never wrote.
function pathLiteralValue(node) {
  // A bare string literal, or the leading literal of a `+' chain.
  //
  // The second case is the ordinary REST-with-an-id shape and skipping it
  // loses most of a client's routes:
  //
  //     this.post("public/game/delete" + "/" + game.id, ...)
  //
  // The leftmost operand is a literal the source wrote, and it is exactly the
  // static part of the path. Reading it is not inferring anything -- the
  // server writes the same prefix on its own side, as "/public/game/delete/
  // :gameid" -- so the two ends still meet on strings both of them spelled.
  // What is dropped is everything after the first non-literal, which is the
  // part neither side can know without running the code.
  if (!node) return null;
  if (node.type === 'Literal') {
    return typeof node.value === 'string' ? node.value : null;
  }
  if (node.type === 'BinaryExpression' && node.operator === '+') {
    return pathLiteralValue(node.left);
  }
  return null;
}

function collectPathLiterals(call, callee, out) {
  const args = call.arguments || [];
  for (let i = 0; i < args.length; i++) {
    const value = pathLiteralValue(args[i]);
    if (typeof value !== 'string') continue;
    if (value.indexOf('/') < 0) continue;
    if (/\s/.test(value)) continue;
    out.push({ callee: callee, index: i, value: value });
  }
}

// The name of a callee, for :call-names, and the bare property that name was
// built from. Only the parts that can resolve to a definition somewhere in the
// tree are worth recording.
//
//   foo()               -> foo
//   obj.method()        -> obj.method   (the receiver, and the property)
//   this.method()       -> Class.method inside a class body
//   obj.a.b()           -> b            (the receiver is not a name)
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
// BUG-0036 is why a member call carries its receiver rather than the property
// alone. `log.commit()' contributed COMMIT, which matched every plain function
// of that name in the repository and no method, since a method entity is named
// Class.method. Module scope cannot narrow it -- a property is not a module
// binding -- so the name arrived at resolution with nothing on it to narrow by.
// The receiver is the one piece of evidence the source actually wrote, and
// LOOM-GRAPH:MEMBER-CALL-PARTS is what reads it back: OBJ.METHOD matches a
// method of a class spelled OBJ, and falls back to the property when no class
// is spelled that way.
//
// `this.method()' is the case where the receiver's type is not a guess: the
// enclosing class is the one the extractor is walking. It is qualified with
// that class's name, which resolves to exactly one method.
//
// A computed member call -- obj[expr]() -- yields nothing, which is CON-0001:
// an unresolvable name is a recorded gap, not a guess.
//
// PROPERTY is reported alongside NAME because the route join reads it. DES-0025
// declares route-carrying callees by their bare spelling -- get, post, sendGet,
// sendPost -- and front-end writes most of them as `this.post(...)', so a
// qualified callee on a literal argument would leave every route unmatched.
function calleeNames(node, className) {
  if (!node) return null;
  if (node.type === 'Identifier') {
    return GLOBAL_VALUES.has(node.name)
      ? null
      : { name: node.name, property: node.name };
  }
  if (node.type === 'MemberExpression' && !node.computed) {
    const property = node.property && node.property.type === 'Identifier'
      ? node.property.name
      : null;
    if (!property) return null;
    const object = node.object;
    if (object && object.type === 'Identifier') {
      if (GLOBAL_VALUES.has(object.name)) return null;
      return { name: object.name + '.' + property, property: property };
    }
    if (object && object.type === 'ThisExpression' && className) {
      return { name: className + '.' + property, property: property };
    }
    // A receiver that is not a name -- a nested member, a call's result, or
    // `this' outside a class body. There is nothing to qualify with, so this
    // is the property alone: the answer every member call gave before
    // BUG-0036, kept for the population the receiver cannot narrow.
    return { name: property, property: property };
  }
  return null;
}

// The name of a JSX element: <Thing />, <Thing.Sub />, <div />.
// Lowercase single-word names are host elements (div, span) and never resolve
// to a definition, so they are dropped here rather than travelling as call
// names nothing can match.
// A superclass expression names a class entity, and a class entity's name is
// never qualified -- so this is the property alone, which is what CALLEE-NAMES
// reported for every member expression before BUG-0036 gave calls a receiver.
function superclassName(node) {
  const named = calleeNames(node, null);
  return named ? named.property : null;
}

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
// The runner's forms (REQ-0053)
// ---------------------------------------------------------------------------
//
// `describe', `it' and `test' are what vitest, jest, mocha and node:test are
// all called from. What is reported here is the shape: which calls are cases,
// which are suites, what each is titled and what its callback reaches.
// Whether a file holding them is a file the runner would run is a judgement
// about the repository, and js-analyzer.lisp makes it (DES-0045 D1).

const CASE_CALLS = new Set(['it', 'test']);
const SUITE_CALLS = new Set(['describe']);
const HOOK_CALLS = new Set(['beforeEach', 'beforeAll', 'afterEach', 'afterAll']);

// The identifier a callee is rooted at, looking through the two shapes the
// runners hang off one: the modifier chain (`it.skip', `describe.only') and
// the call that returns a case function (`it.each(table)(title, fn)').
function calleeRoot(node) {
  let cursor = node;
  for (;;) {
    if (!cursor) return null;
    if (cursor.type === 'MemberExpression' && !cursor.computed) { cursor = cursor.object; continue; }
    if (cursor.type === 'CallExpression') { cursor = cursor.callee; continue; }
    break;
  }
  return cursor.type === 'Identifier' ? cursor.name : null;
}

// A title the index can carry: a string literal, or a template with nothing
// interpolated into it. `it(`fails for ${name}`)' is one title at collection
// time and N at run time, and which of the N this entity would be is not
// something the source says -- so it has no title here and the analyzer counts
// it rather than inventing one.
function literalTitle(node) {
  if (!node) return null;
  if (node.type === 'Literal') return typeof node.value === 'string' ? node.value : null;
  if (node.type === 'TemplateLiteral' && node.expressions.length === 0 && node.quasis.length === 1) {
    return node.quasis[0].value.cooked;
  }
  return null;
}

// STATEMENT as a test form, or null. The callback is the last function
// argument: `it(title, fn)', `it(title, fn, timeout)' and `it.todo(title)'
// with none at all are all written in the wild.
function testForm(statement) {
  let node = statement;
  if (node.type === 'ExpressionStatement') node = node.expression;
  while (node.type === 'AwaitExpression') node = node.argument;
  if (node.type !== 'CallExpression') return null;
  const root = calleeRoot(node.callee);
  if (!root) return null;
  const role = SUITE_CALLS.has(root) ? 'suite'
    : CASE_CALLS.has(root) ? 'case'
      : HOOK_CALLS.has(root) ? 'hook' : null;
  if (!role) return null;
  let callback = null;
  for (const argument of node.arguments) {
    if (FUNCTION_TYPES.has(argument.type)) callback = argument;
  }
  return { role, callback, node, title: role === 'hook' ? null : literalTitle(node.arguments[0]) };
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
  const fileLiteralArgs = [];

  function record(kind, name, node, extra) {
    const definition = Object.assign({
      kind,
      name,
      startLine: node.loc.start.line,
      endLine: node.loc.end.line,
      calls: [],
      jsx: [],
      literalArgs: [],
    }, extra || {});
    definitions.push(definition);
    return definition;
  }

  // Walk BODY attributing every call and JSX usage to OWNER. Nested function
  // expressions do not get their own entity -- an inline callback is not
  // something another file can name -- so their calls belong to the enclosing
  // named definition, which is what makes `impact` on a hook reach the
  // component that uses it.
  function walkBody(node, owner, className) {
    const calls = owner ? owner.calls : fileCalls;
    const usages = owner ? owner.jsx : fileJsx;
    const literals = owner ? owner.literalArgs : fileLiteralArgs;
    const stack = [node];
    while (stack.length) {
      const current = stack.pop();
      if (current.type === 'CallExpression' || current.type === 'NewExpression') {
        const callee = calleeNames(current.callee, className);
        if (callee) {
          calls.push(callee.name);
          collectPathLiterals(current, callee.property, literals);
        }
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
      if (member.value) walkBody(member.value, definition, className);
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
          superclass: init.superClass ? superclassName(init.superClass) : null,
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
          superclass: node.superClass ? superclassName(node.superClass) : null,
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

  // -------------------------------------------------------------------------
  // The runner's forms, walked in addition to the ordinary walk above
  // -------------------------------------------------------------------------
  //
  // In addition rather than instead: a file whose `test' is its own function
  // and not the runner's must index exactly as it does today, and that is
  // decided on the Lisp side, after this has already run (DES-0045 D1).

  let unnamedTests = 0;

  // What a call reaches, into a bucket of the shape WALK-BODY writes to, so
  // the two walks cannot drift apart on what counts as a call.
  function reaches(node) {
    const bucket = { calls: [], jsx: [], literalArgs: [] };
    walkBody(node, bucket);
    return bucket;
  }

  // The calls that run around every case in BODY. Inside a describe callback
  // that is every statement which is not itself a case or a suite -- the hooks
  // and the bare setup both. At module level it is the hooks alone: a module
  // body also holds imports, helpers and constants, which are the file's and
  // not any case's.
  function setupCalls(body, hooksOnly) {
    const calls = [];
    const jsx = [];
    for (const statement of body) {
      const form = testForm(statement);
      if (form && (form.role === 'case' || form.role === 'suite')) continue;
      const source = form ? form.callback : (hooksOnly ? null : statement);
      if (!source) continue;
      const bucket = reaches(source);
      calls.push(...bucket.calls);
      jsx.push(...bucket.jsx);
    }
    return { calls, jsx };
  }

  // Two passes over BODY, because a `beforeEach' may be written after the
  // cases it sets up and a source-order walk would miss it for exactly those.
  //
  // NAMED is false once an enclosing suite's own title could not be read. Its
  // cases are then countable and not nameable: a qualified name missing a
  // segment would collide with a sibling suite's.
  function walkTestBody(body, prefix, inherited, hooksOnly, named) {
    const setup = named ? setupCalls(body, hooksOnly) : { calls: [], jsx: [] };
    const context = {
      calls: inherited.calls.concat(setup.calls),
      jsx: inherited.jsx.concat(setup.jsx),
    };
    for (const statement of body) {
      const form = testForm(statement);
      if (!form) continue;
      if (form.role === 'suite') {
        const inner = form.callback && form.callback.body;
        if (!inner || inner.type !== 'BlockStatement') continue;
        const titled = named && form.title !== null;
        walkTestBody(inner.body,
                     titled ? (prefix ? prefix + ' > ' + form.title : form.title) : prefix,
                     context, false, titled);
      } else if (form.role === 'case') {
        if (!named || form.title === null) { unnamedTests += 1; continue; }
        const bucket = form.callback ? reaches(form.callback) : { calls: [], jsx: [] };
        record('test', prefix ? prefix + ' > ' + form.title : form.title, form.node, {
          suite: prefix || null,
          calls: context.calls.concat(bucket.calls),
          jsx: context.jsx.concat(bucket.jsx),
        });
      }
    }
  }

  walkTestBody(ast.body, '', { calls: [], jsx: [] }, true, true);

  return { definitions, imports, exports, fileCalls, fileJsx, fileLiteralArgs,
           unnamedTests };
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
                fileLiteralArgs: [], unnamedTests: 0,
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
                exports: [], fileCalls: [], fileJsx: [], fileLiteralArgs: [],
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
