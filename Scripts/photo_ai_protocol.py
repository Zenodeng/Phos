"""Phos JSON wire format, shared by exports, evaluation and the local server.

Property order is a token-level contract for constrained decoding, although it
does not change JSON Schema semantics. Never derive it from an expected answer.
"""
import hashlib
import json

VERSION = 'phos-json-compact-v1'
ORDERS = {
    'plan': ['summary', 'adjustments', 'masks', 'curves', 'hsl', 'grading'],
    'mask': ['kind', 'target', 'brightness', 'inverted', 'geometry', 'adjustments', 'name'],
    'crop': ['x', 'y', 'width', 'height'],
    'geometry': ['x0', 'y0', 'x1', 'y1', 'radiusX', 'radiusY', 'feather'],
    'luminance': ['lumLow', 'lumHigh', 'lumSoft'],
    'color': ['hue', 'sat', 'lum'],
    'parameters': ['exposure', 'contrast', 'highlights', 'shadows', 'whites', 'blacks', 'temperature', 'tint', 'grain', 'vignette'],
}
FINGERPRINT = hashlib.sha256(json.dumps({'version': VERSION, 'orders': ORDERS,
    'fallback': 'sorted', 'separators': [',', ':'], 'whitespace': ''}, sort_keys=True).encode()).hexdigest()


def keys(properties):
    names = set(properties)
    kind = ('plan' if 'summary' in names else 'mask' if 'kind' in names else
            'crop' if names == {'x', 'y', 'width', 'height'} else
            'geometry' if 'x0' in names else 'luminance' if 'lumLow' in names else
            'color' if names <= {'hue', 'sat', 'lum'} else 'parameters')
    priority = ORDERS[kind]
    return [k for k in priority if k in names] + sorted(names - set(priority))


def ordered_schema(node):
    if isinstance(node, list):
        return [ordered_schema(x) for x in node]
    if not isinstance(node, dict):
        return node
    result = {k: ordered_schema(v) for k, v in node.items()}
    if 'properties' in result:
        props = result['properties']
        result['properties'] = {k: props[k] for k in keys(props)}
    return result


def serialize_target(value):
    def order(node):
        if isinstance(node, list):
            return [order(x) for x in node]
        if isinstance(node, dict):
            return {k: order(node[k]) for k in keys(node)}
        return node
    return json.dumps(order(value), ensure_ascii=False, separators=(',', ':'), allow_nan=False)


def build_logits_processor(tokenizer, schema):
    import llguidance
    from mlx_vlm.structured import LLGuidanceLogitsProcessor, build_json_schema_logits_processor
    if isinstance(schema, str):
        schema = json.loads(schema)
    reordered = ordered_schema(schema)
    if json.dumps(reordered, sort_keys=True) != json.dumps(schema, sort_keys=True):
        raise ValueError('Schema reordering changed validation semantics')
    original = build_json_schema_logits_processor(tokenizer, schema)
    grammar = llguidance.JsonCompiler(separators=(',', ':'), whitespace_pattern='').compile(
        json.dumps(reordered, ensure_ascii=False))
    return LLGuidanceLogitsProcessor(grammar, original.llg_tokenizer)
