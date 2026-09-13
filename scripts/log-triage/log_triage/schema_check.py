"""Minimal JSON Schema (draft 2020-12 subset) validator used by the tests and the
``--validate-schema`` developer check. Supports: type (incl. unions), properties,
required, additionalProperties, items, enum, const, minimum, maximum, minItems,
maxItems, pattern, anyOf, oneOf, allOf and local ``$ref`` (``#/$defs/...``)."""
from __future__ import annotations

import re
from typing import Any, Dict, List

_TYPES = {
    "object": lambda v: isinstance(v, dict),
    "array": lambda v: isinstance(v, list),
    "string": lambda v: isinstance(v, str),
    "integer": lambda v: isinstance(v, int) and not isinstance(v, bool),
    "number": lambda v: isinstance(v, (int, float)) and not isinstance(v, bool),
    "boolean": lambda v: isinstance(v, bool),
    "null": lambda v: v is None,
}


def _resolve(ref: str, root: Dict[str, Any]) -> Dict[str, Any]:
    if not ref.startswith("#/"):
        raise ValueError("only local refs supported: %s" % ref)
    node: Any = root
    for part in ref[2:].split("/"):
        node = node[part.replace("~1", "/").replace("~0", "~")]
    return node


def validate(instance: Any, schema: Dict[str, Any], root: Dict[str, Any] = None, path: str = "$") -> List[str]:
    """Return a list of error strings (empty when valid)."""
    root = root if root is not None else schema
    errors: List[str] = []
    if "$ref" in schema:
        return validate(instance, _resolve(schema["$ref"], root), root, path)
    t = schema.get("type")
    if t is not None:
        types = t if isinstance(t, list) else [t]
        if not any(_TYPES[x](instance) for x in types):
            return ["%s: expected type %s, got %s" % (path, "/".join(types), type(instance).__name__)]
    if "const" in schema and instance != schema["const"]:
        errors.append("%s: expected const %r" % (path, schema["const"]))
    if "enum" in schema and instance not in schema["enum"]:
        errors.append("%s: %r not in enum %r" % (path, instance, schema["enum"]))
    if isinstance(instance, (int, float)) and not isinstance(instance, bool):
        if "minimum" in schema and instance < schema["minimum"]:
            errors.append("%s: %r < minimum %r" % (path, instance, schema["minimum"]))
        if "maximum" in schema and instance > schema["maximum"]:
            errors.append("%s: %r > maximum %r" % (path, instance, schema["maximum"]))
    if isinstance(instance, str) and "pattern" in schema and not re.search(schema["pattern"], instance):
        errors.append("%s: %r does not match %s" % (path, instance[:60], schema["pattern"]))
    if isinstance(instance, dict):
        for req in schema.get("required", []):
            if req not in instance:
                errors.append("%s: missing required property %r" % (path, req))
        props = schema.get("properties", {})
        for k, v in instance.items():
            if k in props:
                errors.extend(validate(v, props[k], root, path + "." + k))
            else:
                ap = schema.get("additionalProperties", True)
                if ap is False:
                    errors.append("%s: additional property %r not allowed" % (path, k))
                elif isinstance(ap, dict):
                    errors.extend(validate(v, ap, root, path + "." + k))
    if isinstance(instance, list):
        if "minItems" in schema and len(instance) < schema["minItems"]:
            errors.append("%s: fewer than %d items" % (path, schema["minItems"]))
        if "maxItems" in schema and len(instance) > schema["maxItems"]:
            errors.append("%s: more than %d items" % (path, schema["maxItems"]))
        if "items" in schema:
            for i, item in enumerate(instance):
                errors.extend(validate(item, schema["items"], root, "%s[%d]" % (path, i)))
    for key in ("anyOf", "oneOf"):
        if key in schema:
            results = [validate(instance, sub, root, path) for sub in schema[key]]
            ok = [r for r in results if not r]
            if key == "anyOf" and not ok:
                errors.append("%s: matches none of anyOf (%s)" % (path, "; ".join(r[0] for r in results if r)[:300]))
            if key == "oneOf" and len(ok) != 1:
                errors.append("%s: matches %d of oneOf, expected exactly 1" % (path, len(ok)))
    if "allOf" in schema:
        for sub in schema["allOf"]:
            errors.extend(validate(instance, sub, root, path))
    return errors
