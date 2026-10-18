"""Owned MLX-VLM entrypoint; no modifications to installed third-party packages."""
import importlib
import importlib.metadata
import hashlib
import json
import sys
from pathlib import Path
# Imports inside a signed .app must not add __pycache__ files to its seal.
sys.dont_write_bytecode = True
from photo_ai_protocol import VERSION, FINGERPRINT, build_logits_processor

LEGACY_ADAPTER_SHA256 = '9311d57db7b28b48c1c38a56c73f274b0674313860dc180b51a3032a1914737a'
LEGACY_ADAPTER_CONFIG_SHA256 = 'f2e1caefb5fde494bfdb365c0a61c2f2aecb3f791590ee4c29445d25bde54185'


def digest(path):
    with path.open('rb') as handle:
        return hashlib.file_digest(handle, 'sha256').hexdigest()


def verify_identity(model, adapter, lock):
    for name, expected in lock['files'].items():
        if digest(model / name) != expected:
            raise ValueError('Base file fingerprint mismatch: ' + name)
    adapter_hash = None
    config_hash = None
    if adapter:
        manifest = json.loads((adapter / 'manifest.json').read_text())
        adapter_hash = digest(adapter / 'adapters.safetensors')
        if (manifest.get('baseRepo') != lock['repo'] or manifest.get('baseRevision') != lock['revision'] or
                manifest.get('baseConfigSHA256') != lock['files']['config.json'] or manifest.get('adapterSHA256') != adapter_hash):
            raise ValueError('Adapter/base fingerprint mismatch')
        if not (adapter / 'adapter_config.json').is_file():
            raise ValueError('Missing adapter configuration')
        config_hash = digest(adapter / 'adapter_config.json')
        expected_config = manifest.get('adapterConfigSHA256')
        if expected_config is None and adapter_hash == LEGACY_ADAPTER_SHA256:
            expected_config = LEGACY_ADAPTER_CONFIG_SHA256
        if config_hash != expected_config:
            raise ValueError('Adapter configuration fingerprint mismatch')
        if 'serializationVersion' not in manifest and adapter_hash == LEGACY_ADAPTER_SHA256:
            pass  # Explicit, hash-pinned legacy pilot compatibility, never arbitrary legacy weights.
        elif manifest.get('serializationVersion') != VERSION or manifest.get('decoderFingerprint') != FINGERPRINT:
            raise ValueError('Adapter serialization contract mismatch')
    return {'baseRevision': lock['revision'], 'baseConfigSHA256': lock['files']['config.json'],
            'adapterSHA256': adapter_hash, 'adapterConfigSHA256': config_hash}


def main():
    version = importlib.metadata.version('mlx-vlm')
    if version != '0.7.8':
        raise RuntimeError('Phos server integration requires verified mlx-vlm 0.7.8, got ' + version)
    def argument(flag):
        return Path(sys.argv[sys.argv.index(flag) + 1]) if flag in sys.argv else None
    model = argument('--model')
    adapter = argument('--adapter-path')
    if model is None:
        raise ValueError('Phos requires an explicitly pinned --model')
    lock_path = Path(__file__).with_name('model-manifest.json')
    if not lock_path.exists():
        lock_path = Path(__file__).resolve().parents[1] / 'Tools/OptionalModel/model-manifest.json'
    identity = verify_identity(model, adapter, json.loads(lock_path.read_text()))
    identity['protocolImplementationSHA256'] = digest(Path(__file__).with_name('photo_ai_protocol.py'))
    server = importlib.import_module('mlx_vlm.server')
    app_module = importlib.import_module('mlx_vlm.server.app')
    # This version resolves the factory via the package at request time.
    server.build_json_schema_logits_processor = build_logits_processor
    app_module.build_json_schema_logits_processor = build_logits_processor

    @app_module.app.get('/phos/protocol')
    def protocol():
        return {'serializationVersion': VERSION, 'decoderFingerprint': FINGERPRINT,
                'mlxVLMVersion': version, **identity}

    server.main()


if __name__ == '__main__':
    main()
