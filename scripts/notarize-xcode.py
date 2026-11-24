#!/usr/bin/python3
"""Notarize the built app using the Apple account already signed into Xcode."""
import argparse
import datetime
import pathlib
import plistlib
import subprocess
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import appconfig  # noqa: E402

ROOT = appconfig.ROOT
NAME = appconfig.load()['APP_NAME']


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['upload', 'export'])
    parser.add_argument('--team-id', help='Apple Developer Team ID, required for upload')
    parser.add_argument('--archive', type=pathlib.Path)
    parser.add_argument('--output', type=pathlib.Path, default=ROOT / 'dist/notarized')
    args = parser.parse_args()
    app = ROOT / 'dist' / f'{NAME}.app'
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    archive = (args.archive or ROOT / f'dist/{NAME}-{info["CFBundleShortVersionString"]}-{info["CFBundleVersion"]}.xcarchive').resolve()
    if args.action == 'upload':
        if not args.team_id:
            parser.error('--team-id is required for upload')
        subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
        details = subprocess.run(['codesign', '-dv', '--verbose=2', str(app)], capture_output=True, text=True, check=True).stderr.splitlines()
        identity = next((line.removeprefix('Authority=') for line in details if line.startswith('Authority=Developer ID Application:')), None)
        if not identity or f'TeamIdentifier={args.team_id}' not in details:
            parser.error('The app must be Developer ID signed by the selected team first.')
        if archive.exists():
            parser.error('Archive already exists. Use export to check processing, or choose a new --archive path for a new submission.')
        payload = archive / 'Products/Applications' / f'{NAME}.app'
        payload.parent.mkdir(parents=True)
        subprocess.run(['ditto', str(app), str(payload)], check=True)
        metadata = {
            'ArchiveVersion': 2, 'CreationDate': datetime.datetime.utcnow(),
            'Name': NAME, 'SchemeName': NAME,
            'ApplicationProperties': {
                'ApplicationPath': f'Applications/{NAME}.app',
                'Architectures': ['arm64', 'x86_64'],
                'CFBundleIdentifier': info['CFBundleIdentifier'],
                'CFBundleShortVersionString': info['CFBundleShortVersionString'],
                'CFBundleVersion': info['CFBundleVersion'],
                'SigningIdentity': identity, 'Team': args.team_id
            }
        }
        (archive / 'Info.plist').write_bytes(plistlib.dumps(metadata))
        options = archive / f'{NAME}ExportOptions.plist'
        options.write_bytes(plistlib.dumps({
            'method': 'developer-id', 'destination': 'upload', 'signingStyle': 'manual',
            'signingCertificate': identity, 'teamID': args.team_id,
            'manageAppVersionAndBuildNumber': False
        }))
        subprocess.run(['xcodebuild', '-exportArchive', '-archivePath', str(archive), '-exportOptionsPlist', str(options), '-exportPath', str(args.output.resolve())], check=True)
        print(f'Uploaded. Once Apple finishes processing, run: scripts/notarize-xcode.py export --archive {archive}')
    else:
        if not archive.is_dir():
            parser.error('Archive not found')
        subprocess.run(['xcodebuild', '-exportNotarizedApp', '-archivePath', str(archive), '-exportPath', str(args.output.resolve())], check=True)
        exported = args.output.resolve() / f'{NAME}.app'
        subprocess.run(['codesign', '--verify', '--deep', '--strict', str(exported)], check=True)
        subprocess.run(['xcrun', 'stapler', 'validate', str(exported)], check=True)
        subprocess.run(['spctl', '--assess', '--type', 'execute', '--verbose=2', str(exported)], check=True)
        print(f'Notarized app: {exported}')


if __name__ == '__main__':
    try:
        main()
    except (OSError, subprocess.CalledProcessError) as error:
        print(f'Notarization step failed: {error}', file=sys.stderr)
        sys.exit(1)
