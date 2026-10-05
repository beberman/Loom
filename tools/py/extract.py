#!/usr/bin/env python3
"""The Python half of the Python analyzer (DES-0053).

A long-lived child process: the parent writes framed requests on stdin and
reads one line of JSON per request on stdout. The frame is the one
tools/js/extract.js reads, so the parent needs no JSON writer:

    <path>\\n<byte-length>\\n<source bytes>

This file extracts and binds; it does not decide what anything means to the
graph. python-analyzer.lisp decides which definition becomes which entity.
What lives here is what only Python's own grammar and scoping can answer, and
those are single-file facts: which statement a name is bound by (D2), where a
syntax error ends one statement and starts the next (D7), and which calls read
the environment (D10).

It runs as `python3 -I -B`. -I keeps PYTHONPATH, the user site directory and
the current directory off sys.path, so a tree holding its own ast.py or json.py
cannot replace a module imported below. -B writes no .pyc into anybody's tree.

It imports ast, builtins, json, sys and tokenize and nothing from the tree it
reads, and it never calls exec, eval, importlib, or compile in exec mode. The
source is parsed to a tree and walked. Nothing it reads is run (R2).

The reply, camelCase keys, one JSON object per frame:

    path, lineCount, pythonVersion
    docstring       the module docstring, or null
    imports         one entry per bound name, every scope:
                    local, specifier, name, source, line, scope
    definitions     function, method and class, in source order
    variables       a name assigned at module level
    statements      calls made by module-level statements that are neither a
                    definition nor an assignment
    envReads, unnamedEnvReads
                    the file-level environment reads
    damage, error, piecesParsed
                    only on a SyntaxError (D7)
"""
import ast
import builtins
import json
import sys
import tokenize

sys.setrecursionlimit(10000)

BUILTINS = frozenset(dir(builtins))

FUNCTIONS = (ast.FunctionDef, ast.AsyncFunctionDef)
COMPREHENSIONS = (ast.ListComp, ast.SetComp, ast.DictComp, ast.GeneratorExp)
TRY = tuple(t for t in (ast.Try, getattr(ast, 'TryStar', None)) if t)

# Statements that continue the one before them. A column-0 `else:` is not a
# new top-level statement, and splitting there would report a valid statement
# as damage (D7).
CONTINUATIONS = frozenset(('else', 'elif', 'except', 'finally'))

ENVIRONMENT_CALLS = frozenset(('os.environ.get', 'os.getenv', 'os.environ.setdefault'))


# ---------------------------------------------------------------------------
# Scopes
# ---------------------------------------------------------------------------

class Scope:
    """A Python scope. A name maps to (kind, import-entry-or-None), where kind
    is 'import', 'def', 'class', 'var' or 'param'."""

    def __init__(self, kind, parent):
        self.kind = kind
        self.parent = parent
        self.module = parent.module if parent else self
        self.names = {}
        self.globals = set()
        self.nonlocals = set()


def bind(scope, name, kind, entry=None):
    if name in scope.globals:
        # `global x` makes this name the module's. An assignment through it
        # rebinds a module name, so it lands there and not in the function.
        scope = scope.module
        if name in scope.names:
            return
    elif name in scope.nonlocals:
        return
    previous = scope.names.get(name)
    if kind == 'var' and previous and previous[0] == 'import':
        # `try: import json` / `except ImportError: json = None` is the common
        # shape, and the import is what the calls mean. Last-wins would turn
        # every json.dumps into a member call on a local.
        return
    scope.names[name] = (kind, entry)


def lookup(name, scope):
    """The (scope, binding) a name resolves to, or None.

    A class body does not enclose the functions inside it: Python looks a name
    up in the class's own scope only while executing the class body itself.
    """
    first = True
    while scope is not None:
        if name in scope.globals:
            scope = scope.module
        elif scope.kind == 'class' and not first:
            scope = scope.parent
            first = False
            continue
        if name in scope.names:
            return scope, scope.names[name]
        scope = scope.parent
        first = False
    return None


def parameters(args):
    out = list(args.posonlyargs) + list(args.args) + list(args.kwonlyargs)
    if args.vararg:
        out.append(args.vararg)
    if args.kwarg:
        out.append(args.kwarg)
    return [a.arg for a in out]


# ---------------------------------------------------------------------------
# Reading names out of syntax
# ---------------------------------------------------------------------------

def chain_of(expr):
    """(root, attributes) for a.b.c, or (expr, []) when expr is no attribute
    chain. The root is whatever the chain starts from."""
    attrs = []
    while isinstance(expr, ast.Attribute):
        attrs.append(expr.attr)
        expr = expr.value
    attrs.reverse()
    return expr, attrs


def simple_name(expr):
    if isinstance(expr, ast.Name):
        return expr.id
    if isinstance(expr, ast.Attribute):
        return expr.attr
    if isinstance(expr, ast.Subscript):
        return simple_name(expr.value)
    if isinstance(expr, ast.Call):
        return simple_name(expr.func)
    return None


def format_parameter(arg, default):
    text = arg.arg
    if arg.annotation is not None:
        text += ': ' + ast.unparse(arg.annotation)
    if default is not None:
        text += (' = ' if arg.annotation is not None else '=') + ast.unparse(default)
    return text


def format_arguments(a):
    """The parameters as written: defaults and annotations included, with `/`,
    `*`, `*args` and `**kwargs` left in."""
    out = []
    positional = list(a.posonlyargs) + list(a.args)
    defaults = [None] * (len(positional) - len(a.defaults)) + list(a.defaults)
    for index, (arg, default) in enumerate(zip(positional, defaults)):
        out.append(format_parameter(arg, default))
        if a.posonlyargs and index == len(a.posonlyargs) - 1:
            out.append('/')
    if a.vararg:
        out.append('*' + format_parameter(a.vararg, None))
    elif a.kwonlyargs:
        out.append('*')
    for arg, default in zip(a.kwonlyargs, a.kw_defaults):
        out.append(format_parameter(arg, default))
    if a.kwarg:
        out.append('**' + format_parameter(a.kwarg, None))
    return out


def literal_value(node):
    """A decorator argument as D3 records it: a literal's value, bare names, or
    the marker 'expression'."""
    if isinstance(node, ast.UnaryOp) and isinstance(node.op, (ast.USub, ast.UAdd)) \
            and isinstance(node.operand, ast.Constant) \
            and isinstance(node.operand.value, (int, float)) \
            and not isinstance(node.operand.value, bool):
        value = node.operand.value
        return {'kind': 'literal', 'value': -value if isinstance(node.op, ast.USub) else value}
    if isinstance(node, ast.Constant) and (node.value is None
                                           or isinstance(node.value, (str, int, float, bool))):
        return {'kind': 'literal', 'value': node.value}
    if isinstance(node, ast.Name):
        return {'kind': 'names', 'value': [node.id]}
    if isinstance(node, (ast.List, ast.Tuple)) and node.elts \
            and all(isinstance(e, ast.Name) for e in node.elts):
        return {'kind': 'names', 'value': [e.id for e in node.elts]}
    return {'kind': 'expression'}


class EnvSink:
    """The environment reads of one owner: literal names, and a count of reads
    whose key was not a literal."""

    def __init__(self):
        self.names = []
        self.unnamed = 0

    def add(self, name):
        if name is None:
            self.unnamed += 1
        elif name not in self.names:
            self.names.append(name)


class Owner:
    """What calls and environment reads are attributed to while walking."""

    def __init__(self, env):
        self.calls = []
        self.env = env


# ---------------------------------------------------------------------------
# The extractor
# ---------------------------------------------------------------------------

class Extractor:
    def __init__(self):
        self.imports = []
        self.definitions = []
        self.variables = []
        self.statements = []
        self.file_env = EnvSink()
        self.module_scope = None

    # -- bindings ----------------------------------------------------------

    def collect(self, scope, nodes):
        for node in nodes:
            self.collect_node(scope, node)

    def collect_node(self, scope, node):
        t = type(node)
        if t in FUNCTIONS:
            bind(scope, node.name, 'def')
            return
        if t is ast.ClassDef:
            bind(scope, node.name, 'class')
            return
        if t is ast.Lambda or t in COMPREHENSIONS:
            return
        if t is ast.Global:
            scope.globals.update(node.names)
        elif t is ast.Nonlocal:
            scope.nonlocals.update(node.names)
        elif t is ast.Import:
            for alias in node.names:
                self.bind_import(scope, node, alias)
        elif t is ast.ImportFrom:
            for alias in node.names:
                self.bind_from(scope, node, alias)
        elif t is ast.Name and isinstance(node.ctx, (ast.Store, ast.Del)):
            bind(scope, node.id, 'var')
        elif t is ast.ExceptHandler and node.name:
            bind(scope, node.name, 'var')
        elif t in (ast.MatchAs, ast.MatchStar) and node.name:
            bind(scope, node.name, 'var')
        elif t is ast.MatchMapping and node.rest:
            bind(scope, node.rest, 'var')
        for child in ast.iter_child_nodes(node):
            self.collect_node(scope, child)

    def add_import(self, scope, node, local, specifier, name, source):
        entry = {'local': local, 'specifier': specifier, 'name': name,
                 'source': source, 'line': node.lineno,
                 'scope': 'module' if scope.kind == 'module' else scope.kind}
        self.imports.append(entry)
        if local is not None:
            bind(scope, local, 'import', entry)

    def bind_import(self, scope, node, alias):
        if alias.asname:
            self.add_import(scope, node, alias.asname, alias.name, None, alias.name)
        else:
            # `import a.b.c` binds `a`. The statement's source is a.b.c and the
            # binding's module is a: a.b.c.f() walks from a.
            self.add_import(scope, node, alias.name.split('.')[0],
                            alias.name.split('.')[0], None, alias.name)

    def bind_from(self, scope, node, alias):
        specifier = '.' * node.level + (node.module or '')
        if alias.name == '*':
            self.add_import(scope, node, None, specifier, '*', specifier)
        else:
            self.add_import(scope, node, alias.asname or alias.name,
                            specifier, alias.name, specifier)

    # -- classifying calls -------------------------------------------------

    def import_binding(self, expr, scope):
        """(entry, attribute path) when expr is rooted in an import binding."""
        root, attrs = chain_of(expr)
        if isinstance(root, ast.Name):
            found = lookup(root.id, scope)
            if found and found[1][0] == 'import':
                return found[1][1], attrs
        return None

    def import_path(self, expr, scope):
        bound = self.import_binding(expr, scope)
        if not bound:
            return None
        entry, attrs = bound
        return entry['specifier'], ([entry['name']] if entry['name'] else []) + attrs

    def dotted(self, expr, scope):
        path = self.import_path(expr, scope)
        return '.'.join([path[0]] + path[1]) if path else None

    def classify(self, func, scope, cls):
        """D2's five bindings, or None for a call that names nothing in this
        tree: a builtin, or a name only a function's own scope binds."""
        if isinstance(func, ast.Name):
            found = lookup(func.id, scope)
            if found is None:
                # No scope binds it, so Python looks in builtins and nowhere
                # else. An unbound name that is no builtin stays a bare name:
                # a gap, not a guess (DES-0053 DEFERRED, `from x import *`).
                return None if func.id in BUILTINS else {'kind': 'local', 'name': func.id}
            owner_scope, (kind, entry) = found
            if kind == 'import':
                return {'kind': 'import', 'specifier': entry['specifier'],
                        'path': [entry['name']] if entry['name'] else []}
            if owner_scope.kind == 'module':
                return {'kind': 'local', 'name': func.id}
            return None
        if isinstance(func, ast.Attribute):
            root, attrs = chain_of(func)
            if isinstance(root, ast.Name):
                path = self.import_path(func, scope)
                if path:
                    return {'kind': 'import', 'specifier': path[0], 'path': path[1]}
                if root.id in ('self', 'cls') and cls and len(attrs) == 1:
                    return {'kind': 'self', 'name': cls + '.' + attrs[0]}
                if root.id in BUILTINS and lookup(root.id, scope) is None:
                    # str.join, dict.fromkeys: the receiver is a language
                    # global, as extract.js drops JSON.stringify.
                    return None
                if len(attrs) == 1:
                    return {'kind': 'member', 'name': root.id + '.' + attrs[0]}
                return {'kind': 'member', 'name': attrs[-1]}
            if isinstance(root, ast.Call) and isinstance(root.func, ast.Name) \
                    and root.func.id == 'super' and lookup('super', scope) is None:
                # super().m() reaches a base class's m, which a bare `m` would
                # fan out across every class defining one.
                return None
            return {'kind': 'member', 'name': attrs[-1]}
        return None

    def record_call(self, func, node, scope, owner, cls):
        record = self.classify(func, scope, cls)
        if record is not None:
            record['line'] = node.lineno
            if isinstance(node, ast.Call):
                record['positional'] = len(node.args)
                record['keywords'] = [k.arg for k in node.keywords if k.arg]
            else:
                record['positional'] = 0
                record['keywords'] = []
            owner.calls.append(record)
        return record

    # -- environment reads (D10) -------------------------------------------

    def note_environment_call(self, node, scope, owner):
        if self.dotted(node.func, scope) not in ENVIRONMENT_CALLS:
            return
        key = node.args[0] if node.args else next(
            (k.value for k in node.keywords if k.arg == 'key'), None)
        # Only the key is read. The default is never recorded.
        owner.env.add(key.value if isinstance(key, ast.Constant)
                      and isinstance(key.value, str) else None)

    def note_environment_subscript(self, node, scope, owner):
        if not isinstance(node.ctx, ast.Load) or self.dotted(node.value, scope) != 'os.environ':
            return
        key = node.slice
        owner.env.add(key.value if isinstance(key, ast.Constant)
                      and isinstance(key.value, str) else None)

    # -- walking expressions and nested scopes -----------------------------

    def visit(self, node, scope, owner, cls):
        t = type(node)
        if t is ast.Call:
            self.visit_call(node, scope, owner, cls)
        elif t is ast.Subscript:
            self.note_environment_subscript(node, scope, owner)
            self.visit_children(node, scope, owner, cls)
        elif t in FUNCTIONS:
            self.enter_function(node, scope, owner, cls)
        elif t is ast.Lambda:
            self.visit_defaults(node.args, scope, owner, cls)
            inner = Scope('function', scope)
            for name in parameters(node.args):
                bind(inner, name, 'param')
            self.visit(node.body, inner, owner, cls)
        elif t is ast.ClassDef:
            self.enter_nested_class(node, scope, owner)
        elif t in COMPREHENSIONS:
            self.visit_comprehension(node, scope, owner, cls)
        else:
            self.visit_children(node, scope, owner, cls)

    def visit_children(self, node, scope, owner, cls):
        for child in ast.iter_child_nodes(node):
            self.visit(child, scope, owner, cls)

    def visit_call(self, node, scope, owner, cls):
        self.record_call(node.func, node, scope, owner, cls)
        self.note_environment_call(node, scope, owner)
        self.visit_call_parts(node, scope, owner, cls)

    def visit_call_parts(self, node, scope, owner, cls):
        """The receiver and arguments of a call already recorded."""
        if isinstance(node.func, ast.Attribute):
            # The receiver can hold calls of its own: f().g().
            self.visit(node.func.value, scope, owner, cls)
        elif not isinstance(node.func, ast.Name):
            self.visit(node.func, scope, owner, cls)
        for arg in node.args:
            self.visit(arg, scope, owner, cls)
        for keyword in node.keywords:
            self.visit(keyword.value, scope, owner, cls)

    def visit_comprehension(self, node, scope, owner, cls):
        inner = Scope('comp', scope)
        generators = node.generators
        for generator in generators:
            self.collect(inner, [generator.target])
        # The first iterable is evaluated where the comprehension is written.
        self.visit(generators[0].iter, scope, owner, cls)
        for index, generator in enumerate(generators):
            if index:
                self.visit(generator.iter, inner, owner, cls)
            for condition in generator.ifs:
                self.visit(condition, inner, owner, cls)
        if isinstance(node, ast.DictComp):
            self.visit(node.key, inner, owner, cls)
            self.visit(node.value, inner, owner, cls)
        else:
            self.visit(node.elt, inner, owner, cls)

    def visit_defaults(self, args, scope, owner, cls):
        for default in list(args.defaults) + [d for d in args.kw_defaults if d is not None]:
            self.visit(default, scope, owner, cls)

    def visit_decorator(self, decorator, scope, owner, cls):
        """A decorator is a call made by what it decorates. Returns its D3
        record."""
        func = decorator.func if isinstance(decorator, ast.Call) else decorator
        record = {'name': ast.unparse(func), 'line': decorator.lineno, 'arguments': []}
        path = self.import_path(func, scope)
        if path:
            record['specifier'], record['path'] = path
        self.record_call(func, decorator, scope, owner, cls)
        if isinstance(decorator, ast.Call):
            for keyword in decorator.keywords:
                if keyword.arg:
                    record['arguments'].append(
                        {'name': keyword.arg, 'value': literal_value(keyword.value)})
            self.visit_call_parts(decorator, scope, owner, cls)
        elif isinstance(func, ast.Attribute):
            self.visit(func.value, scope, owner, cls)
        return record

    def enter_function(self, node, scope, owner, cls):
        """Walk a def: its decorators and defaults in the enclosing scope, its
        body in its own. Returns the decorator records. Whatever the def
        contains is attributed to OWNER, which is the def's own entity for a
        module-level function or method and the enclosing entity for a nested
        one."""
        decorators = [self.visit_decorator(d, scope, owner, cls) for d in node.decorator_list]
        self.visit_defaults(node.args, scope, owner, cls)
        inner = Scope('function', scope)
        for name in parameters(node.args):
            bind(inner, name, 'param')
        self.collect(inner, node.body)
        for statement in node.body:
            self.visit(statement, inner, owner, cls)
        return decorators

    def enter_nested_class(self, node, scope, owner):
        for decorator in node.decorator_list:
            self.visit_decorator(decorator, scope, owner, None)
        for base in node.bases:
            self.visit(base, scope, owner, None)
        for keyword in node.keywords:
            self.visit(keyword.value, scope, owner, None)
        inner = Scope('class', scope)
        self.collect(inner, node.body)
        for statement in node.body:
            # A nested class gets no entity, and the `self` of its methods is
            # not the enclosing class's.
            self.visit(statement, inner, owner, None)

    # -- the statements that mint entities ---------------------------------

    def module_statement(self, statement):
        owner = Owner(self.file_env)
        self.statement(statement, self.module_scope, 'module', None, owner)
        if owner.calls:
            self.statements.append({'startLine': statement.lineno,
                                    'endLine': statement.end_lineno,
                                    'calls': owner.calls})

    def statement(self, node, scope, mode, class_record, owner):
        t = type(node)
        cls = class_record['name'] if class_record else None
        if t in FUNCTIONS:
            self.definition(node, scope, class_record)
        elif t is ast.ClassDef:
            if mode == 'module':
                self.class_definition(node, scope)
            else:
                self.enter_nested_class(node, scope, owner)
        elif mode == 'module' and self.is_plain_assignment(node):
            self.variable(node, scope)
        elif t is ast.If or t is ast.While:
            self.visit(node.test, scope, owner, cls)
            self.block(node.body + node.orelse, scope, mode, class_record, owner)
        elif t in (ast.For, ast.AsyncFor):
            self.visit(node.target, scope, owner, cls)
            self.visit(node.iter, scope, owner, cls)
            self.block(node.body + node.orelse, scope, mode, class_record, owner)
        elif t in (ast.With, ast.AsyncWith):
            for item in node.items:
                self.visit(item.context_expr, scope, owner, cls)
                if item.optional_vars is not None:
                    self.visit(item.optional_vars, scope, owner, cls)
            self.block(node.body, scope, mode, class_record, owner)
        elif t in TRY:
            self.block(node.body, scope, mode, class_record, owner)
            for handler in node.handlers:
                if handler.type is not None:
                    self.visit(handler.type, scope, owner, cls)
                self.block(handler.body, scope, mode, class_record, owner)
            self.block(node.orelse + node.finalbody, scope, mode, class_record, owner)
        elif t is getattr(ast, 'Match', None):
            self.visit(node.subject, scope, owner, cls)
            for case in node.cases:
                if case.guard is not None:
                    self.visit(case.guard, scope, owner, cls)
                self.block(case.body, scope, mode, class_record, owner)
        else:
            if mode == 'class' and class_record is not None:
                self.note_slots(node, class_record)
            self.visit(node, scope, owner, cls)

    def block(self, statements, scope, mode, class_record, owner):
        for statement in statements:
            self.statement(statement, scope, mode, class_record, owner)

    @staticmethod
    def is_plain_assignment(node):
        def names_only(target):
            return isinstance(target, ast.Name) or (
                isinstance(target, (ast.Tuple, ast.List)) and target.elts
                and all(isinstance(e, ast.Name) for e in target.elts))
        if isinstance(node, ast.Assign):
            return all(names_only(t) for t in node.targets)
        return isinstance(node, ast.AnnAssign) and node.value is not None \
            and isinstance(node.target, ast.Name)

    def variable(self, node, scope):
        targets = node.targets if isinstance(node, ast.Assign) else [node.target]
        names = []
        for target in targets:
            names += [target.id] if isinstance(target, ast.Name) else [e.id for e in target.elts]
        env = EnvSink()
        owner = Owner(env)
        self.visit(node.value, scope, owner, None)
        for index, name in enumerate(dict.fromkeys(names)):
            # One statement's calls belong to one entity: `A, B = f()` is one
            # call, and minting it twice would count it twice.
            first = index == 0
            self.variables.append({
                'name': name, 'startLine': node.lineno, 'endLine': node.end_lineno,
                'calls': owner.calls if first else [],
                'envReads': env.names if first else [],
                'unnamedEnvReads': env.unnamed if first else 0})

    def note_slots(self, node, class_record):
        if isinstance(node, ast.Assign):
            names = [t.id for t in node.targets if isinstance(t, ast.Name)]
        elif isinstance(node, ast.AnnAssign) and isinstance(node.target, ast.Name):
            names = [node.target.id]
        else:
            return
        for name in names:
            if name not in class_record['slots']:
                class_record['slots'].append(name)

    def definition(self, node, scope, class_record):
        owner = Owner(EnvSink())
        cls = class_record['name'] if class_record else None
        decorators = self.enter_function(node, scope, owner, cls)
        first = node.decorator_list[0].lineno if node.decorator_list else node.lineno
        self.definitions.append({
            'kind': 'method' if class_record else 'function',
            'name': cls + '.' + node.name if class_record else node.name,
            'className': cls,
            'startLine': first, 'endLine': node.end_lineno, 'defLine': node.lineno,
            'arguments': format_arguments(node.args),
            'decorators': decorators,
            'docstring': ast.get_docstring(node),
            'calls': owner.calls,
            'envReads': owner.env.names, 'unnamedEnvReads': owner.env.unnamed})

    def class_definition(self, node, scope):
        # A class body's calls, and its decorators', belong to the class. Its
        # environment reads go to the file: a :CLASS carries no
        # :ENVIRONMENT-READS.
        owner = Owner(self.file_env)
        decorators = [self.visit_decorator(d, scope, owner, None) for d in node.decorator_list]
        bases = []
        for base in node.bases:
            self.visit(base, scope, owner, None)
            record = {'text': ast.unparse(base), 'name': simple_name(base)}
            path = self.import_path(base, scope)
            if path:
                record['specifier'], record['path'] = path
                # Alias undone: `from unittest import TestCase as T` is TestCase.
                record['name'] = path[1][-1] if path[1] else record['name']
            bases.append(record)
        for keyword in node.keywords:
            self.visit(keyword.value, scope, owner, None)
        first = node.decorator_list[0].lineno if node.decorator_list else node.lineno
        record = {'kind': 'class', 'name': node.name, 'className': None,
                  'startLine': first, 'endLine': node.end_lineno, 'defLine': node.lineno,
                  'decorators': decorators, 'docstring': ast.get_docstring(node),
                  'bases': bases, 'slots': [], 'calls': owner.calls}
        self.definitions.append(record)
        inner = Scope('class', scope)
        self.collect(inner, node.body)
        self.block(node.body, inner, 'class', record, owner)

    # -- the whole module --------------------------------------------------

    def run(self, body):
        scope = Scope('module', None)
        self.module_scope = scope
        self.collect(scope, body)
        # `global x` in any function makes x a module name, wherever the
        # function sits.
        for node in ast.walk(ast.Module(body=body, type_ignores=[])):
            if isinstance(node, ast.Global):
                for name in node.names:
                    scope.names.setdefault(name, ('var', None))
        for statement in body:
            self.module_statement(statement)
        self.imports.sort(key=lambda e: e['line'])


# ---------------------------------------------------------------------------
# A syntax error costs its statement, not the file (D7)
# ---------------------------------------------------------------------------

def split_lines(source):
    parts = source.split('\n')
    return [p + '\n' for p in parts[:-1]] + ([parts[-1]] if parts[-1] else [])


def statement_ranges(source):
    """(start, end) line pairs, one per top-level statement.

    A statement starts at a token that tokenize places at column 0, outside any
    bracket and string, after a NEWLINE token. A decorator and the def under it
    are one statement, and so is an `if` with its `else`. If tokenize itself
    fails, the last range runs to the end of the file.
    """
    all_lines = split_lines(source)
    lines = iter(all_lines)
    skipped = (tokenize.NL, tokenize.COMMENT, tokenize.INDENT, tokenize.DEDENT,
               tokenize.ENDMARKER, tokenize.NEWLINE)
    starts, ends = [], []
    at_start, after_decorator, last_end, complete = True, False, None, True
    try:
        for token in tokenize.generate_tokens(lambda: next(lines, '')):
            if token.type == tokenize.NEWLINE:
                at_start = True
                continue
            if token.type in skipped:
                continue
            if at_start:
                at_start = False
                column = token.start[1]
                if not starts or (column == 0 and not after_decorator
                                  and token.string not in CONTINUATIONS):
                    if starts:
                        ends.append(last_end)
                    starts.append(token.start[0])
                after_decorator = token.type == tokenize.OP and token.string == '@'
            last_end = token.end[0]
    except (tokenize.TokenError, SyntaxError):
        complete = False
    if not starts:
        return [(1, max(len(all_lines), 1))]
    # The last line of text, not LINE-COUNT: a trailing newline starts no line.
    ends.append(last_end if complete else len(all_lines))
    return list(zip(starts, ends))


def parse_pieces(source):
    """(modules parsed, damage, first error text, first piece parsed)."""
    lines = split_lines(source)
    modules, damage, first_error, first_ok = [], [], None, False
    for index, (start, end) in enumerate(statement_ranges(source)):
        # Padded so every line number in the piece is the file's own.
        text = '\n' * (start - 1) + ''.join(lines[start - 1:end])
        try:
            modules.append(ast.parse(text))
            if index == 0:
                first_ok = True
        except (SyntaxError, ValueError, RecursionError, MemoryError) as error:
            message = '%s: %s' % (type(error).__name__,
                                  getattr(error, 'msg', None) or error)
            line = getattr(error, 'lineno', None)
            if line:
                message += ' (line %d)' % line
            damage.append({'startLine': start, 'endLine': end, 'message': message})
            first_error = first_error or message
    return modules, damage, first_error, first_ok


def analyze(path, source):
    source = source.lstrip('﻿')
    line_count = 0 if source == '' else len(source.split('\n'))
    reply = {'path': path, 'lineCount': line_count, 'pythonVersion': sys.version}
    first_module = None
    try:
        tree = ast.parse(source)
        body, first_module = tree.body, tree
    except (SyntaxError, ValueError, RecursionError, MemoryError):
        modules, damage, first_error, first_ok = parse_pieces(source)
        body = [statement for module in modules for statement in module.body]
        first_module = modules[0] if modules and first_ok else None
        reply['damage'] = damage
        reply['piecesParsed'] = len(modules)
        # The version is part of the message: python3 3.12 cannot parse syntax
        # added in 3.13, and that is the interpreter's age and not the file's.
        reply['error'] = '%s [python %s]' % (first_error, sys.version.split()[0])
    extractor = Extractor()
    extractor.run(body)
    reply['docstring'] = ast.get_docstring(first_module) if first_module else None
    reply['imports'] = extractor.imports
    reply['definitions'] = extractor.definitions
    reply['variables'] = extractor.variables
    reply['statements'] = extractor.statements
    reply['envReads'] = extractor.file_env.names
    reply['unnamedEnvReads'] = extractor.file_env.unnamed
    return reply


# ---------------------------------------------------------------------------
# The frame loop
# ---------------------------------------------------------------------------

def read_exactly(stream, count):
    chunks = []
    while count > 0:
        chunk = stream.read(count)
        if not chunk:
            break
        chunks.append(chunk)
        count -= len(chunk)
    return b''.join(chunks)


def main():
    stdin, stdout = sys.stdin.buffer, sys.stdout.buffer
    while True:
        header = stdin.readline()
        if not header:
            break
        path = header.decode('utf-8', 'replace').rstrip('\r\n')
        length = int(stdin.readline())
        source = read_exactly(stdin, length).decode('utf-8', 'replace')
        try:
            reply = analyze(path, source)
        except Exception as error:  # a reply is owed whatever the file holds
            reply = {'path': path, 'lineCount': 0, 'pythonVersion': sys.version,
                     'error': '%s: %s [python %s]' % (type(error).__name__, error,
                                                      sys.version.split()[0]),
                     'damage': [], 'piecesParsed': 0, 'docstring': None, 'imports': [],
                     'definitions': [], 'variables': [], 'statements': [],
                     'envReads': [], 'unnamedEnvReads': 0}
        stdout.write((json.dumps(reply, ensure_ascii=False) + '\n').encode('utf-8', 'replace'))
        stdout.flush()


if __name__ == '__main__':
    main()
