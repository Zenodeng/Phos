#!/usr/bin/env python3
"""Token-level compatibility and versioned export; original datasets stay intact."""
import argparse
import collections
import hashlib
import json
from pathlib import Path
from photo_ai_protocol import VERSION, FINGERPRINT, build_logits_processor, serialize_target


def verify(root, model, out):
    root, model, out = root.resolve(), model.resolve(), out.resolve()
    from transformers import AutoTokenizer
    from llguidance import LLMatcher
    import jsonschema
    tokenizer = AutoTokenizer.from_pretrained(model, local_files_only=True)
    grammars, answers, report, hashes = {}, {}, [], {}
    out.mkdir(parents=True, exist_ok=True)
    for split in ('train', 'validation', 'test'):
        original = root / 'sft' / (split + '.jsonl')
        rows = [json.loads(x) for x in original.read_text().splitlines()]
        hashes[str(original)] = hashlib.sha256(original.read_bytes()).hexdigest()
        for row in rows:
            record = json.loads((root / 'records' / (row['id'] + '.json')).read_text())
            schema_path = root / record['renderPath'] / 'protocol' / ('crop-schema.json' if row['task'] == 'crop' else 'edit-schema.json')
            schema = json.loads(schema_path.read_text())
            digest = hashlib.sha256(json.dumps(schema, sort_keys=True).encode()).hexdigest()
            if digest not in grammars:
                grammars[digest] = build_logits_processor(tokenizer, schema)
            processor = grammars[digest]
            old = row['messages'][-1]['content']
            canonical = serialize_target(json.loads(old))
            jsonschema.validate(json.loads(canonical), schema)
            checks = []
            for answer in (old, canonical):
                key = (digest, answer)
                if key not in answers:
                    ids = tokenizer.encode(answer, add_special_tokens=False)
                    matcher = LLMatcher(processor.llg_tokenizer, processor.grammar)
                    answers[key] = matcher.validate_tokens(ids) == len(ids)
                checks.append(answers[key])
            if not checks[1]:
                raise ValueError('Canonical target rejected by decoder: ' + row['id'])
            assert json.loads(canonical) == json.loads(old)
            row['messages'][-1]['content'] = canonical
            row['serializationVersion'] = VERSION
            row['decoderFingerprint'] = FINGERPRINT
            report.append({'id': row['id'], 'split': split, 'oldCompatible': checks[0], 'canonicalCompatible': checks[1], 'formatChanged': old != canonical})
        target = out / (split + '.jsonl')
        target.write_text(''.join(json.dumps(r, ensure_ascii=False) + '\n' for r in rows))
        hashes[str(target)] = hashlib.sha256(target.read_bytes()).hexdigest()
    result = {'serializationVersion': VERSION, 'decoderFingerprint': FINGERPRINT,
              'counts': dict(collections.Counter(r['split'] for r in report)),
              'originalCompatible': sum(r['oldCompatible'] for r in report),
              'canonicalCompatible': sum(r['canonicalCompatible'] for r in report),
              'changed': sum(r['formatChanged'] for r in report),
              'total': len(report), 'hashes': hashes, 'checks': report,
              'scope': 'All label tokens checked against decoder; semantic labels unchanged; test images not model-evaluated.'}
    (out / 'protocol-verification.json').write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
    print({k: v for k, v in result.items() if k not in ('checks', 'hashes')}, flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--model', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    verify(args.root, args.model, args.out)
