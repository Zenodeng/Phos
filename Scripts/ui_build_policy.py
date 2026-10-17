#!/usr/bin/env python3
"""Shared metadata and verification for the macOS 26 UI build pipeline."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys


def write_report(path, data):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2))


def run(*args):
    return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT).strip()


def version(text):
    if not re.fullmatch(r'\d+\.\d+(?:\.\d+)?', text):
        raise ValueError('Invalid SDK/deployment version: ' + text)
    return tuple(map(int, text.split('.'))) + (0,) * (3 - len(text.split('.')))


def configure(args):
    data = dict(status='blocked', nativeGlass=False, interactiveGlass=False,
                coreGlassRequired=True, target=args.target, requestedSDK=args.sdk,
                flags=[], linkerFlags=[])
    try:
        if args.target != 'arm64-apple-macosx26.0':
            raise ValueError('Full App/UI builds require arm64-apple-macosx26.0.')
        if os.environ.get('PHOS_DISABLE_NATIVE_GLASS') == '1':
            raise ValueError('Compile-time glass disabling is no longer supported. '
                             'Runtime material fallback remains available via phos.ui.disableNativeGlass.')
        sdk = Path(args.sdk or run('xcrun', '--sdk', 'macosx', '--show-sdk-path')).resolve(strict=True)
        if '\n' in str(sdk) or '\r' in str(sdk):
            raise ValueError('SDK paths cannot contain line breaks.')
        settings_path = sdk / 'SDKSettings.plist'
        settings = plistlib.loads(settings_path.read_bytes())
        if not isinstance(settings, dict):
            raise ValueError('SDKSettings.plist must contain a dictionary.')
        sdk_version = str(settings['Version'])
        if version(sdk_version) < version('26.0'):
            raise ValueError('A macOS SDK version 26.0 or later is required: ' + sdk_version)
        if 'macosx' not in settings.get('SupportedTargets', {}):
            raise ValueError('The selected SDK does not declare a macosx target.')
        compiler = run('swiftc', '--version')
        link_flags = ['-Xlinker', '-platform_version', '-Xlinker', 'macos',
                      '-Xlinker', '26.0', '-Xlinker', sdk_version]
        data.update(status='configured', sdk=str(sdk), sdkVersion=sdk_version,
                    minimumOS='26.0', compiler=compiler,
                    sdkSettingsSHA256=hashlib.sha256(settings_path.read_bytes()).hexdigest(),
                    linkerFlags=link_flags, interactiveGlassReason='not-required-by-macos26-core')
        write_report(args.report, data)
        print(str(sdk))
        print(sdk_version)
        print('26.0')
    except (ValueError, OSError, KeyError, plistlib.InvalidFileException, subprocess.CalledProcessError) as error:
        data.update(reason='invalid-build-configuration', error=str(error))
        write_report(args.report, data)
        print('Phos UI build blocked: ' + str(error), file=sys.stderr)
        return 1
    return 0


def probe_result(args):
    data = json.loads(Path(args.report).read_text())
    log = Path(args.log)
    data['diagnostics'] = {'native.log': log.read_text() if log.exists() else ''}
    probe = Path(args.probe)
    exists = probe.is_file()
    data['probeSHA256'] = hashlib.sha256(probe.read_bytes()).hexdigest() if exists else None
    ok = args.result == 'passed' and exists
    data.update(status='ready' if ok else 'blocked', nativeGlass=ok,
                reason='actual-api-probe-passed' if ok else 'core-glass-api-probe-failed',
                flags=['-D', 'PHOS_NATIVE_GLASS'] if ok else [])
    if not exists:
        data['reason'] = 'missing-probe-source'
    write_report(args.report, data)
    return 0 if exists or args.result == 'failed' else 1


def verify(args):
    configuration = json.loads(Path(args.configuration).read_text())
    data = dict(status='blocked', configuration=str(Path(args.configuration).resolve()))
    try:
        if configuration.get('status') != 'ready' or not configuration.get('nativeGlass'):
            raise ValueError('Build configuration did not pass the mandatory core API probe.')
        subject = Path(args.subject).resolve(strict=True)
        if args.bundle:
            info = plistlib.loads((subject / 'Contents/Info.plist').read_bytes())
            if version(str(info['LSMinimumSystemVersion'])) != version(configuration['minimumOS']):
                raise ValueError('Bundle Info.plist minimum does not match the build configuration.')
            executable = Path(info['CFBundleExecutable'])
            if executable.name != str(executable) or executable.name in ('', '.', '..'):
                raise ValueError('Invalid bundle executable name.')
            binary = subject / 'Contents/MacOS' / executable
            run('codesign', '--verify', '--deep', '--strict', str(subject))
            data.update(bundleMinimumOS=info['LSMinimumSystemVersion'],
                        bundleID=info.get('CFBundleIdentifier'), codeSignatureVerified=True)
        else:
            binary = subject
        architecture = run('lipo', '-archs', str(binary))
        if architecture != 'arm64':
            raise ValueError('Expected one arm64 slice, got: ' + architecture)
        raw = run('xcrun', 'vtool', '-show-build', str(binary))
        platforms = re.findall(r'^\s*platform\s+(\S+)', raw, re.M)
        minimums = re.findall(r'^\s*minos\s+(\S+)', raw, re.M)
        sdks = re.findall(r'^\s*sdk\s+(\S+)', raw, re.M)
        if platforms != ['MACOS'] or len(minimums) != 1 or len(sdks) != 1:
            raise ValueError('Expected one macOS LC_BUILD_VERSION record.')
        if version(minimums[0]) != version(configuration['minimumOS']):
            raise ValueError('Mach-O minimum does not match the build configuration: ' + minimums[0])
        if version(sdks[0]) != version(configuration['sdkVersion']):
            raise ValueError('Linked SDK differs from the frontend SDK: ' + sdks[0])
        data.update(status='passed', subject=str(subject), binary=str(binary),
                    architecture=architecture, minimumOS=minimums[0], linkedSDK=sdks[0],
                    frontendSDK=configuration['sdk'], frontendSDKVersion=configuration['sdkVersion'],
                    binarySHA256=hashlib.sha256(binary.read_bytes()).hexdigest(), rawBuildVersion=raw)
    except (ValueError, OSError, KeyError, plistlib.InvalidFileException, subprocess.CalledProcessError) as error:
        data.update(error=str(error))
        write_report(args.report, data)
        print('Phos build verification blocked: ' + str(error), file=sys.stderr)
        return 1
    write_report(args.report, data)
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    config = commands.add_parser('configure')
    config.add_argument('sdk')
    config.add_argument('target')
    config.add_argument('report')
    config.set_defaults(handler=configure)
    probe = commands.add_parser('probe-result')
    probe.add_argument('report')
    probe.add_argument('probe')
    probe.add_argument('log')
    probe.add_argument('result', choices=['passed', 'failed'])
    probe.set_defaults(handler=probe_result)
    check = commands.add_parser('verify')
    check.add_argument('subject')
    check.add_argument('configuration')
    check.add_argument('report')
    check.add_argument('--bundle', action='store_true')
    check.set_defaults(handler=verify)
    args = parser.parse_args()
    return args.handler(args)


if __name__ == '__main__':
    sys.exit(main())
