#!/usr/bin/env python3
"""json-schema-check.py: schema/benchbar.schema.json against what reads it.

Run with `python3 -I`. No dependency: it holds a validator for the small part of
JSON Schema 2020-12 the schema uses, and a keyword it does not know is an error,
so the schema cannot quietly grow past what is checked. The checks:

  fixtures   every recorded fixture of the apps validates (schema/fixtures.map)
  validate   DEF FILE...  one or more files (a .jsonl line each) against a definition
  live       DEF FILE...  as validate, and every field the schema lists must be printed
                          (a field marked x-conditional may be absent)
  models     the Swift and C# models and mcp.py read only fields the schema has, and need
                          only fields it requires (schema/models.map)
  docs       the JSON docs (docs/json-schema.md, docs/reference/json) and the schema name the same fields

Exit 1 when a check fails, with one line per problem.
"""

import ast
import glob
import json
import os
import re
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
SCHEMA_PATH = os.path.join(ROOT, "schema", "benchbar.schema.json")
IGNORED = {"$schema", "$id", "$comment", "$defs", "title", "description", "default", "examples"}
KNOWN = {"$ref", "type", "enum", "const", "properties", "required", "items", "allOf", "anyOf", "oneOf"}


class SchemaError(Exception):
    pass


def load_schema():
    with open(SCHEMA_PATH) as f:
        return json.load(f)


def type_ok(value, name):
    if name == "null":
        return value is None
    if name == "boolean":
        return isinstance(value, bool)
    if name == "integer":
        return isinstance(value, int) and not isinstance(value, bool)
    if name == "number":
        return isinstance(value, (int, float)) and not isinstance(value, bool)
    return isinstance(value, {"string": str, "array": list, "object": dict}[name])


class Validator:
    def __init__(self, root, live=False):
        self.root = root
        self.live = live

    def resolve(self, schema):
        while "$ref" in schema:
            ref = schema["$ref"]
            if not ref.startswith("#/$defs/") or ref[8:] not in self.root["$defs"]:
                raise SchemaError("unknown reference " + ref)
            target = self.root["$defs"][ref[8:]]
            rest = {k: v for k, v in schema.items() if k != "$ref"}
            schema = dict(target, **rest) if rest else target
            if rest and "properties" in rest and "properties" in target:
                raise SchemaError("a $ref with its own properties: " + ref)
        return schema

    def check(self, value, schema, path="$", strict=None):
        """A list of problems (empty when value fits schema)."""
        if strict is None:
            strict = self.live
        schema = self.resolve(schema)
        for key in schema:
            if key not in KNOWN and key not in IGNORED and not key.startswith("x-"):
                raise SchemaError("keyword not supported by the checker: " + key)
        if schema.get("x-conditional"):
            strict = False
        errors = []
        if "type" in schema:
            names = schema["type"] if isinstance(schema["type"], list) else [schema["type"]]
            if not any(type_ok(value, n) for n in names):
                return ["%s: expected %s, got %s" % (path, "|".join(names), json.dumps(value)[:60])]
        if "const" in schema and (value != schema["const"] or type(value) is not type(schema["const"])):
            errors.append("%s: expected %s, got %s" % (path, json.dumps(schema["const"]), json.dumps(value)[:60]))
        if "enum" in schema and value not in schema["enum"]:
            errors.append("%s: %s is not one of %s" % (path, json.dumps(value)[:60], ", ".join(json.dumps(e) for e in schema["enum"])))
        if isinstance(value, dict):
            props = schema.get("properties", {})
            for name in schema.get("required", []):
                if name not in value:
                    errors.append("%s: required field %s is missing" % (path, name))
            for name, sub in props.items():
                if name in value:
                    errors += self.check(value[name], sub, path + "." + name, strict)
                elif strict and not self.resolve(sub).get("x-conditional") and not sub.get("x-conditional") and name not in schema.get("required", []):
                    errors.append("%s: the schema lists %s but the CLI did not print it" % (path, name))
        if isinstance(value, list):
            if "items" in schema:
                for i, item in enumerate(value):
                    errors += self.check(item, schema["items"], "%s[%d]" % (path, i), strict)
        for sub in schema.get("allOf", []):
            errors += self.check(value, sub, path, strict)
        if "anyOf" in schema:
            results = [self.check(value, sub, path, strict) for sub in schema["anyOf"]]
            if all(results):
                errors += min(results, key=len)
        if "oneOf" in schema:
            results = [self.check(value, sub, path, strict) for sub in schema["oneOf"]]
            passed = [r for r in results if not r]
            if len(passed) != 1:
                errors += min(results, key=len) if not passed else ["%s: fits %d of the alternatives" % (path, len(passed))]
        return errors


def unknown_keys(root, value, schema, path="$"):
    """Fields of value that no definition on the way names (a typo in a fixture). A schema marked x-open
    (a plan line, a done line, a document without a definition) carries fields of its command: not checked."""
    v = Validator(root)
    out = []
    parts = members(root, schema)
    for m in list(parts):
        for key in ("anyOf", "oneOf"):
            for sub in m.get(key, []):
                parts += members(root, sub)
    if isinstance(value, dict):
        if any(m.get("x-open") for m in parts):
            return out
        known = {}
        for m in parts:
            for k, sub in m.get("properties", {}).items():
                known.setdefault(k, sub)
        for k, x in value.items():
            if k not in known:
                out.append("%s: the schema has no field %s" % (path, k))
            else:
                out += unknown_keys(root, x, known[k], path + "." + k)
    elif isinstance(value, list):
        item = next((m["items"] for m in parts if "items" in m), None)
        if item is not None:
            for i, x in enumerate(value):
                out += unknown_keys(root, x, item, "%s[%d]" % (path, i))
    return out


def documents(path):
    """The JSON values in a file: the whole file, else one per line."""
    with open(path) as f:
        text = f.read()
    try:
        return [json.loads(text)]
    except ValueError:
        pass
    out = []
    for n, line in enumerate(text.splitlines(), 1):
        if line.strip():
            try:
                out.append(json.loads(line))
            except ValueError:
                raise ValueError("%s:%d is not JSON" % (path, n))
    return out


def rel(path):
    return os.path.relpath(path, ROOT)


# ---- schema reading helpers

def resolved(root, schema):
    return Validator(root).resolve(schema)


def members(root, schema):
    """The schemas that make up schema: itself and what its allOf and $ref lead to."""
    schema = resolved(root, schema)
    out = [schema]
    for sub in schema.get("allOf", []):
        out += members(root, sub)
    return out


def properties_of(root, name):
    props = {}
    for m in members(root, {"$ref": "#/$defs/" + name}):
        props.update(m.get("properties", {}))
    return props


def required_of(root, name):
    req = set()
    for m in members(root, {"$ref": "#/$defs/" + name}):
        req.update(m.get("required", []))
    return req


def all_property_names(root, node=None):
    """Every property name under node (default: all definitions), nested ones included."""
    names = set()

    def walk(node):
        if isinstance(node, dict):
            for k, v in node.items():
                if k == "properties" and isinstance(v, dict):
                    names.update(v)
                walk(v)
        elif isinstance(node, list):
            for v in node:
                walk(v)
    walk(root["$defs"] if node is None else node)
    return names


def json_types(root, schema):
    s = resolved(root, schema)
    t = s.get("type")
    if t is None:
        for sub in members(root, schema):
            if "type" in sub:
                t = sub["type"]
    if t is None and "anyOf" in s:
        t = [x for sub in s["anyOf"] for x in (resolved(root, sub).get("type") or [])]
    return set(t if isinstance(t, list) else [t] if t else [])


# ---- the fixtures

def read_map(name):
    rows = []
    with open(os.path.join(ROOT, "schema", name)) as f:
        for n, line in enumerate(f, 1):
            line = line.rstrip("\n")
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            rows.append((n, line.split()))
    return rows


FIXTURE_DIRS = ("macos/BenchBarTests/Fixtures", "windows/tray/fixtures")


def check_fixtures():
    root = load_schema()
    v = Validator(root)
    problems = []
    claimed = {}
    checked = 0
    for n, cols in read_map("fixtures.map"):
        pattern, target = cols[0], cols[1]
        files = sorted(glob.glob(os.path.join(ROOT, pattern), recursive=True))
        if not files:
            problems.append("schema/fixtures.map:%d: %s matches no file" % (n, pattern))
        for path in files:
            claimed.setdefault(path, (n, target))
    for path in sorted(claimed):
        n, target = claimed[path]
        if target == "-":
            continue
        want_invalid = target.startswith("!")
        name = target.lstrip("!")
        if name not in root["$defs"]:
            problems.append("schema/fixtures.map:%d: no definition %s" % (n, name))
            continue
        try:
            docs = documents(path)
        except ValueError as e:
            problems.append(str(e))
            continue
        errs = []
        for i, doc in enumerate(docs):
            found = v.check(doc, {"$ref": "#/$defs/" + name})
            if not found and not want_invalid:
                found = unknown_keys(root, doc, {"$ref": "#/$defs/" + name})
            errs += ["%s line %d %s" % (rel(path), i + 1, e) if len(docs) > 1 else "%s %s" % (rel(path), e) for e in found]
        checked += 1
        if want_invalid and not errs:
            problems.append("%s should not fit %s (schema/fixtures.map:%d) but it does" % (rel(path), name, n))
        elif not want_invalid:
            problems += errs
    for d in FIXTURE_DIRS:
        for path in sorted(glob.glob(os.path.join(ROOT, d, "**", "*.json*"), recursive=True)):
            if path not in claimed:
                problems.append("%s is in no row of schema/fixtures.map" % rel(path))
    return problems, checked


def check_files(live, name, files):
    root = load_schema()
    if name not in root["$defs"]:
        return ["no definition " + name]
    v = Validator(root, live=live)
    problems = []
    for path in files:
        for i, doc in enumerate(documents(path)):
            problems += ["%s #%d %s" % (path, i + 1, e) for e in v.check(doc, {"$ref": "#/$defs/" + name})]
    return problems


# ---- the Swift models

def swift_structs(text):
    """name -> (body, start) of every struct, nested ones as Outer.Inner (bodies without their nested structs)."""
    out = {}

    def scan(start, end, prefix):
        pos = start
        pat = re.compile(r"\bstruct\s+(\w+)\s*(?::[^{]*)?\{")
        while True:
            m = pat.search(text, pos, end)
            if not m:
                return
            depth, i = 1, m.end()
            while depth and i < end:
                if text[i] == "{":
                    depth += 1
                elif text[i] == "}":
                    depth -= 1
                i += 1
            name = prefix + m.group(1)
            inner = text[m.end():i - 1]
            out[name] = inner
            scan(m.end(), i - 1, name + ".")
            pos = i
    scan(0, len(text), "")
    return out


def own_body(body):
    """body without the bodies of nested structs."""
    while True:
        m = re.search(r"\bstruct\s+\w+\s*(?::[^{]*)?\{", body)
        if not m:
            return body
        depth, i = 1, m.end()
        while depth and i < len(body):
            depth += {"{": 1, "}": -1}.get(body[i], 0)
            i += 1
        body = body[:m.start()] + body[i:]


def strip_blocks(body):
    """body without what is inside braces: functions, computed properties, enums."""
    out, depth = [], 0
    for ch in body:
        if ch == "{":
            depth += 1
            if depth == 1:
                out.append("{")
        elif ch == "}":
            depth -= 1
            if depth == 0:
                out.append("}")
        elif depth == 0:
            out.append(ch)
    return "".join(out)


SWIFT_SCALAR = {"String": "string", "Int": "integer", "Int32": "integer", "Int64": "integer", "Double": "number", "Bool": "boolean", "Date": "string"}


def swift_model(text, struct):
    """{json key: (kind, strict)} for what struct decodes, from its source (and its extensions)."""
    structs = swift_structs(text)
    if struct not in structs:
        raise KeyError(struct)
    body = own_body(structs[struct])
    flat = strip_blocks(body)
    props = {}
    lead = r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:public|private|internal|fileprivate|nonisolated)\s+)*"
    for m in re.finditer(lead + r"(let|var)\s+(\w+)\s*:\s*([^={\n]+?)\s*(=\s*[^{\n]+)?(\{)?\s*$", flat, re.M):
        if m.group(5):
            continue  # computed
        props[m.group(2)] = (m.group(1), m.group(3).strip(), bool(m.group(4)))
    props = {k: v for k, v in props.items() if not re.search(r"\bstatic\s+(let|var)\s+" + k + r"\b", flat)}
    # a stored property the pattern above did not read (split over lines, no type) must not vanish quietly
    unparsed = [m.group(1) for m in re.finditer(lead + r"(?:let|var)\s+(\w+)[^\n{]*$", flat, re.M) if m.group(1) not in props
                and not re.search(r"\bstatic\s+(?:let|var)\s+" + m.group(1) + r"\b", flat)
                and not re.search(r"\blet\s+" + m.group(1) + r"\s*=", flat)]
    keys = {}
    ck = re.search(r"enum\s+CodingKeys\b[^{]*\{(.*?)\}", body, re.S)
    if ck:
        for case in re.finditer(r"case\s+([^\n;]+)", ck.group(1)):
            for part in case.group(1).split(","):
                part = part.strip()
                if not part:
                    continue
                m = re.match(r"(\w+)\s*(?:=\s*\"([^\"]+)\")?$", part)
                if m:
                    keys[m.group(1)] = m.group(2) or m.group(1)
    else:
        keys = {k: k for k in props}
    # an extension of the struct or the struct itself with init(from decoder: ...)
    custom = None
    for src in [body] + [m.group(1) for m in re.finditer(r"extension\s+" + re.escape(struct.split(".")[-1]) + r"\b[^{]*\{(.*)", text, re.S)]:
        m = re.search(r"init\(from decoder:[^)]*\)\s*(?:throws)?\s*\{", src)
        if m:
            depth, i = 1, m.end()
            while depth and i < len(src):
                depth += {"{": 1, "}": -1}.get(src[i], 0)
                i += 1
            custom = src[m.end():i - 1]
            break
    out = {}
    if custom is None:
        for prop, key in keys.items():
            if prop not in props:
                continue
            kind, typ, has_default = props[prop]
            if kind == "let" and has_default:
                continue
            out[key] = (typ, not typ.endswith("?") and not has_default)
    else:
        names = {}
        for prop, key in keys.items():
            names[prop] = key
        strict_props = set(re.findall(r"\.decode\([^)]*forKey:\s*\.(\w+)\)", custom)) | set(re.findall(r"lossyList\([^)]*forKey:\s*\.(\w+)\)", custom))
        strict_props |= set(re.findall(r"=\s*try\s+c\.decode\([^)]*forKey:\s*\.(\w+)\)", custom))
        used = set(re.findall(r"forKey:\s*\.(\w+)", custom)) | set(re.findall(r"lenient\(\s*\.(\w+)", custom))
        for prop in used:
            if prop in names:
                typ = props.get(prop, ("var", "?", False))[1]
                out[names[prop]] = (typ, prop in strict_props)
    return out, unparsed


def swift_kind(typ):
    typ = typ.rstrip("?").strip()
    if typ in SWIFT_SCALAR:
        return ("scalar", SWIFT_SCALAR[typ])
    m = re.match(r"\[(\w+)\]$", typ)
    if m and m.group(1) in SWIFT_SCALAR:
        return ("array", SWIFT_SCALAR[m.group(1)])
    return None


def type_clash(root, schema, kind):
    """A message when the Swift type cannot hold what the schema says the CLI prints, else None."""
    if kind is None:
        return None
    types = json_types(root, schema) - {"null"}
    if kind[0] == "scalar":
        want = kind[1]
        if types and want not in types and not (want == "number" and "integer" in types) and not (want == "integer" and "number" in types):
            return "the schema says %s, the model reads %s" % ("|".join(sorted(types)), want)
    else:
        if types and "array" not in types:
            return "the schema says %s, the model reads an array" % "|".join(sorted(types))
        items = resolved(root, schema).get("items")
        if items is not None:
            it = json_types(root, items) - {"null"}
            if it and kind[1] not in it and not (kind[1] == "number" and "integer" in it):
                return "the schema says an array of %s, the model reads an array of %s" % ("|".join(sorted(it)), kind[1])
    return None


def check_swift(root, file, struct, defs):
    path = os.path.join(ROOT, file)
    with open(path) as f:
        text = f.read()
    try:
        model, unparsed = swift_model(text, struct)
    except KeyError:
        return ["%s: no struct %s (schema/models.map)" % (file, struct)]
    props, required = {}, []
    for d in defs:
        if d not in root["$defs"]:
            return ["schema/models.map: no definition " + d]
        props.update({k: (d, v) for k, v in properties_of(root, d).items()})
        required.append((d, required_of(root, d), set(properties_of(root, d))))
    problems = []
    if not model:
        problems.append("%s %s: read no field (the parser found nothing)" % (file, struct))
    for name in unparsed:
        problems.append("%s %s.%s: a property the checker could not read (put it on one line, with its type)" % (file, struct, name))
    for key, (typ, strict) in sorted(model.items()):
        where = "%s %s.%s" % (file, struct, key)
        if key not in props:
            problems.append("%s: not in the schema (%s)" % (where, "/".join(defs)))
            continue
        clash = type_clash(root, props[key][1], swift_kind(typ))
        if clash:
            problems.append("%s: %s" % (where, clash))
        if strict:
            for d, req, names in required:
                if key in names and key not in req:
                    problems.append("%s: the model needs it, %s does not require it" % (where, d))
    return problems


# ---- the C# models

def cs_dtos(text):
    """class name -> {json key: nullable} for the classes with [JsonPropertyName] properties."""
    out = {}
    for m in re.finditer(r"class\s+(\w+)\s*\{(.*?)\n\}", text, re.S):
        fields = {}
        for p in re.finditer(r'\[JsonPropertyName\("([^"]+)"\)\]\s*public\s+([\w<>\[\],? ]+?)\s+\w+\s*\{', m.group(2)):
            fields[p.group(1)] = p.group(2).strip().endswith("?")
        if fields:
            out[m.group(1)] = fields
    return out


def cs_read_keys(text):
    keys = set()
    for m in re.finditer(r'JsonRead\.\w+\(\s*[\w.]+\s*,\s*"([^"]+)"', text):
        keys.add(m.group(1))
    for m in re.finditer(r'\b\w+\["([a-z_]+)"\]', text):
        keys.add(m.group(1))
    for m in re.finditer(r'ContainsKey\("([^"]+)"\)', text):
        keys.add(m.group(1))
    return keys


def check_cs_dto(root, file, cls, defs):
    with open(os.path.join(ROOT, file)) as f:
        dtos = cs_dtos(f.read())
    if cls not in dtos:
        return ["%s: no class %s with JsonPropertyName fields (schema/models.map)" % (file, cls)]
    props = set()
    required = []
    for d in defs:
        if d not in root["$defs"]:
            return ["schema/models.map: no definition " + d]
        props |= set(properties_of(root, d))
        required.append((d, required_of(root, d), set(properties_of(root, d))))
    problems = []
    for key, nullable in sorted(dtos[cls].items()):
        if key not in props:
            problems.append("%s %s.%s: not in the schema (%s)" % (file, cls, key, "/".join(defs)))
        elif not nullable:
            for d, req, names in required:
                if key in names and key not in req:
                    problems.append("%s %s.%s: the model needs it (not nullable), %s does not require it" % (file, cls, key, d))
    return problems


def swift_read_keys(text):
    """The keys a Swift file reads from a decoded dictionary: object["key"] and $0["key"]."""
    return set(re.findall(r'(?:\b\w+|\$0)\["([a-z_]+)"\]', text))


def check_read_keys(root, file, defs, scan):
    with open(os.path.join(ROOT, file)) as f:
        keys = scan(f.read())
    props = set()
    for d in defs:
        if d not in root["$defs"]:
            return ["schema/models.map: no definition " + d]
        # a definition and the definitions it points at, to any depth
        stack, seen = [d], set()
        while stack:
            cur = stack.pop()
            if cur in seen:
                continue
            seen.add(cur)
            props |= all_property_names(root, root["$defs"][cur])
            text = json.dumps(root["$defs"][cur])
            stack += re.findall(r'#/\$defs/(\w+)', text)
    if not keys:
        return ["%s: reads no key by name (schema/models.map)" % file]
    return ["%s: reads the field %s, which %s do not have" % (file, k, "/".join(defs)) for k in sorted(keys - props)]


# ---- mcp.py

def mcp_reads(text):
    tree = ast.parse(text)
    for node in tree.body:
        if isinstance(node, ast.Assign) and any(getattr(t, "id", "") == "CLI_READS" for t in node.targets):
            return [tuple(ast.literal_eval(e)) for e in node.value.elts], node
    return None, None


def mcp_literal_keys(tree, skip):
    """The string keys the code subscripts or passes to .get(), outside the table node."""
    keys = set()
    for node in ast.walk(tree):
        if node is skip:
            continue
        if isinstance(node, ast.Subscript) and isinstance(node.ctx, ast.Load) and isinstance(node.slice, ast.Constant) and isinstance(node.slice.value, str):
            keys.add(node.slice.value)
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute) and node.func.attr == "get" and node.args \
                and isinstance(node.args[0], ast.Constant) and isinstance(node.args[0].value, str):
            keys.add(node.args[0].value)
    return keys


def walk_path(root, name, path):
    """Follow 'benches[].path' through the schema from definition name; the last schema, its parent's required list."""
    schema = {"$ref": "#/$defs/" + name}
    required = True
    parent_required = set()
    for seg in path.split("."):
        is_list = seg.endswith("[]")
        key = seg[:-2] if is_list else seg
        props = {}
        parent_required = set()
        for m in members(root, schema):
            props.update(m.get("properties", {}))
            parent_required |= set(m.get("required", []))
        if key not in props:
            return None, None
        schema = props[key]
        if is_list:
            s = resolved(root, schema)
            if "array" not in json_types(root, schema) or "items" not in s:
                return None, None
            schema = s["items"]
    return schema, parent_required


def check_mcp(root, file):
    path = os.path.join(ROOT, file)
    with open(path) as f:
        text = f.read()
    reads, node = mcp_reads(text)
    if reads is None:
        return ["%s: no CLI_READS table" % file]
    tree = ast.parse(text)
    used = mcp_literal_keys(tree, node)
    problems = []
    for doc, field, needed in reads:
        if doc not in root["$defs"]:
            problems.append("%s: CLI_READS names the definition %s, which the schema does not have" % (file, doc))
            continue
        schema, parent_required = walk_path(root, doc, field)
        last = field.split(".")[-1].replace("[]", "")
        if schema is None:
            problems.append("%s: CLI_READS reads %s of %s, which the schema does not have" % (file, field, doc))
        elif needed and last not in parent_required:
            problems.append("%s: %s needs %s of %s, which the schema does not require" % (file, file.split("/")[-1], field, doc))
        if last not in used:
            problems.append("%s: CLI_READS lists %s but the code never reads the key %s" % (file, field, last))
    if "outputSchema" in text:
        problems.append("%s: has an outputSchema; check it against the schema here too (schema/models.map)" % file)
    return problems


def mcp_functions(text):
    out = {}
    for fn in ast.walk(ast.parse(text)):
        if isinstance(fn, ast.FunctionDef):
            out[fn.name] = fn
    return out


def check_mcp_readers(root, file, readers, own):
    """The functions that read CLI output read only fields of CLI_READS, and every function that parses
    JSON is one of them or is named as reading something of its own."""
    with open(os.path.join(ROOT, file)) as f:
        text = f.read()
    reads, _node = mcp_reads(text)
    allowed = set(seg.replace("[]", "") for _d, field, _n in reads or [] for seg in field.split("."))
    funcs = mcp_functions(text)
    problems = []
    for name in readers:
        if name not in funcs:
            problems.append("%s: schema/models.map names the function %s, which does not exist" % (file, name))
            continue
        for key in sorted(mcp_literal_keys(funcs[name], None) - allowed):
            problems.append("%s: %s reads the key %s of CLI output, which CLI_READS does not list" % (file, name, key))
    for name, fn in sorted(funcs.items()):
        if "json.loads" in ast.unparse(fn) and name not in readers and name not in own:
            problems.append("%s: %s parses JSON and is in neither the readers nor the own list of schema/models.map" % (file, name))
    return problems


def swift_codable_structs(text):
    """Names (Outer.Inner) of the structs that conform to Codable or Decodable."""
    out = []
    for name in swift_structs(text):
        m = re.search(r"\bstruct\s+" + re.escape(name.split(".")[-1]) + r"\s*:([^{]*)\{", text)
        if m and re.search(r"\b(Codable|Decodable)\b", m.group(1)):
            out.append(name)
    return out


def check_coverage(rows):
    """Every model that reads the CLI's JSON is in a row of models.map, or is skipped there with a reason."""
    mapped, skipped_files, skipped_structs = set(), set(), set()
    for cols in rows:
        if cols[0] in ("swift", "cs"):
            mapped.add((cols[1], cols[2]))
        elif cols[0] in ("csread", "swiftread"):
            mapped.add((cols[1], "*"))
        elif cols[0] == "skipfile":
            skipped_files.add(cols[1])
        elif cols[0] == "skip":
            skipped_structs.add((cols[1], cols[2]))
    mapped_files = set(f for f, _ in mapped)
    problems = []
    for path in sorted(glob.glob(os.path.join(ROOT, "macos", "BenchBar", "CLI", "*.swift"))):
        file = rel(path)
        with open(path) as f:
            structs = swift_codable_structs(f.read())
        if not structs or file in skipped_files:
            continue
        for name in structs:
            if (file, name) not in mapped and (file, name) not in skipped_structs:
                problems.append("%s: struct %s is in no row of schema/models.map (add a swift row, or skip %s %s with a reason)" % (file, name, file, name))
    for path in sorted(glob.glob(os.path.join(ROOT, "windows", "tray", "Tray.Core", "**", "*.cs"), recursive=True)):
        file = rel(path)
        with open(path) as f:
            text = f.read()
        if (cs_dtos(text) or cs_read_keys(text)) and file not in mapped_files and file not in skipped_files:
            problems.append("%s: reads JSON by field name and is in no row of schema/models.map (add a row, or skipfile it with a reason)" % file)
    return problems


def check_models():
    root = load_schema()
    problems = []
    seen = {"swift": 0, "swiftread": 0, "cs": 0, "csread": 0, "mcp": 0}
    rows = read_map("models.map")
    problems += check_coverage([cols for _n, cols in rows])
    for n, cols in rows:
        kind = cols[0]
        seen[kind] = seen.get(kind, 0) + 1
        if kind == "swift":
            problems += check_swift(root, cols[1], cols[2], cols[3:])
        elif kind == "cs":
            problems += check_cs_dto(root, cols[1], cols[2], cols[3:])
        elif kind == "csread":
            problems += check_read_keys(root, cols[1], cols[2:], cs_read_keys)
        elif kind == "swiftread":
            problems += check_read_keys(root, cols[1], cols[2:], swift_read_keys)
        elif kind == "mcp":
            problems += check_mcp(root, cols[1])
        elif kind == "mcpreaders":
            problems += check_mcp_readers(root, cols[1], [c for c in cols[2:] if c != "|"][:cols.index("|") - 2] if "|" in cols else cols[2:],
                                          cols[cols.index("|") + 1:] if "|" in cols else [])
        elif kind not in ("skip", "skipfile"):
            problems.append("schema/models.map:%d: unknown kind %s" % (n, kind))
    return problems, seen


# ---- the prose

def doc_section(prose, heading):
    """The text under the heading (its subsections included), or None."""
    lines = prose.splitlines()
    for n, line in enumerate(lines):
        m = re.match(r"(#+)\s+(.*?)\s*$", line)
        if m and m.group(2) == heading:
            out = []
            for later in lines[n + 1:]:
                h = re.match(r"(#+)\s", later)
                if h and len(h.group(1)) <= len(m.group(1)):
                    break
                out.append(later)
            return "\n".join(out)
    return None


def doc_pages():
    """The JSON pages of the docs: the overview, then one page per command family (docs/reference/json)."""
    paths = [os.path.join(ROOT, "docs", "json-schema.md")]
    folder = os.path.join(ROOT, "docs", "reference", "json")
    if os.path.isdir(folder):
        paths += [os.path.join(folder, n) for n in sorted(os.listdir(folder)) if n.endswith(".md")]
    pages = []
    for path in paths:
        with open(path, encoding="utf-8") as f:
            pages.append(f.read())
    return pages


def check_docs():
    """Every field of a definition is named, in code quotes or as a JSON key, in the section its x-doc names."""
    root = load_schema()
    pages = doc_pages()
    problems = []
    for name, d in root["$defs"].items():
        names = all_property_names(root, d)
        if not names:
            continue
        sections = []
        for heading in d.get("x-doc", []):
            text = None
            for prose in pages:
                text = doc_section(prose, heading)
                if text is not None:
                    break
            if text is None:
                problems.append("%s: x-doc names the heading %r, which no JSON page of the docs has" % (name, heading))
            else:
                sections.append(text)
        if not d.get("x-doc"):
            problems.append("%s: no x-doc (the heading of the JSON docs that describes it)" % name)
            continue
        text = "\n".join(sections)
        for field in sorted(names):
            if not re.search(r'[`".]' + re.escape(field) + r'[`"\[:]', text):
                problems.append("%s: the JSON docs do not mention the field %s under %s" % (name, field, " or ".join(d["x-doc"])))
    return problems


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    cmd = argv[1]
    try:
        if cmd == "fixtures":
            problems, n = check_fixtures()
            print("%d fixtures checked" % n)
        elif cmd in ("validate", "live"):
            problems = check_files(cmd == "live", argv[2], argv[3:])
        elif cmd == "models":
            problems, seen = check_models()
            print("models checked: %d Swift structs, %d Swift files, %d C# classes, %d C# files, %d MCP server" % (seen["swift"], seen["swiftread"], seen["cs"], seen["csread"], seen["mcp"]))
        elif cmd == "docs":
            problems = check_docs()
        else:
            print("unknown command " + cmd)
            return 2
    except SchemaError as e:
        print("schema: %s" % e)
        return 1
    for p in problems:
        print("FAIL: " + p)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
