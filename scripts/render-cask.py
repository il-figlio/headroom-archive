#!/usr/bin/python3
"""Render packaging/homebrew/headroom.rb for the tap from VERSION and the DMG's SHA-256.

    render-cask.py [--dmg PATH | --sha256 HEX] [--output PATH]

Defaults: the DMG in dist/releases/<tag>/ and output next to it as <token>.rb.
Copy the result to Casks/<token>.rb in the tap repo (HOMEBREW_TAP in app.env).
"""
import argparse
import hashlib
import pathlib
import re
import shutil
import subprocess
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import appconfig  # noqa: E402


def main():
    config = appconfig.load()
    out_dir = appconfig.ROOT / 'dist/releases' / config['TAG']
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    source = parser.add_mutually_exclusive_group()
    source.add_argument('--dmg', type=pathlib.Path, default=out_dir / f'{config["APP_NAME"]}-{config["MARKETING_VERSION"]}.dmg')
    source.add_argument('--sha256', help='SHA-256 of the published DMG')
    parser.add_argument('--output', type=pathlib.Path)
    args = parser.parse_args()
    token = config.get('CASK_TOKEN') or config['APP_NAME'].lower()
    digest = args.sha256 or hashlib.sha256(args.dmg.read_bytes()).hexdigest()
    if not re.fullmatch(r'[0-9a-f]{64}', digest):
        parser.error('--sha256 must be 64 lowercase hex characters')
    template = (appconfig.ROOT / 'packaging/homebrew/headroom.rb').read_text()
    body = re.sub(r'\A(?:#.*\n)+', '', template)  # drop the template's own header comment
    rendered = appconfig.render(body, {**config, 'CASK_TOKEN': token, 'DMG_SHA256': digest})
    output = args.output or out_dir / f'{token}.rb'
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(rendered)
    if shutil.which('ruby'):
        subprocess.run(['ruby', '-c', str(output)], check=True, stdout=subprocess.DEVNULL)
    print(output)


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        sys.exit(f'render-cask: {error}')
