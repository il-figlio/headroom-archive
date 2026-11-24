#!/usr/bin/python3
"""Package, sign, verify and publish a public release.

  dry-run   ZIP + DMG + signed appcast + SHA256SUMS + cask from dist/<App>.app,
            offline, with a throwaway Sparkle key, then runs every local check.
  package   ZIP + DMG + SHA256SUMS. Without --local the app must be Developer ID
            signed; it is notarized and stapled (App Store Connect API key from
            HEADROOM_NOTARY_KEY/_KEY_ID/_ISSUER, or --notary-profile), or must
            already be stapled (scripts/notarize-xcode.py path).
  appcast   Signs the ZIP and writes a signed single-item appcast.xml.
  verify    Checks the app, ZIP, DMG, appcast and SHA256SUMS in dist/releases/<tag>.
  publish   Creates a draft GitHub release and uploads the assets (gh CLI).
  promote   After the release is published: verifies the feed and copies it to
            ./appcast.xml for a commit to main. That commit is what ships the update.

Values come from VERSION and packaging/app.env. Sparkle's sign_update reads the
EdDSA key from HEADROOM_SPARKLE_ED_KEY (key text, piped on stdin), --ed-key-file,
or the login Keychain account in SPARKLE_KEYCHAIN_ACCOUNT.
"""
import argparse
import base64
import contextlib
import datetime
import hashlib
import html
import json
import os
import pathlib
import plistlib
import re
import subprocess
import sys
import tempfile
import urllib.request
from xml.etree import ElementTree as ET

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import appconfig  # noqa: E402
import ed25519  # noqa: E402

ROOT = appconfig.ROOT
CONFIG = appconfig.load()
APP_NAME, VERSION, BUILD, TAG, REPO = (CONFIG[k] for k in ('APP_NAME', 'MARKETING_VERSION', 'BUILD_NUMBER', 'TAG', 'GITHUB_REPO'))
APP = ROOT / 'dist' / f'{APP_NAME}.app'
OUT = ROOT / 'dist/releases' / TAG
ZIP = OUT / f'{APP_NAME}-{VERSION}-universal.zip'
DMG = OUT / f'{APP_NAME}-{VERSION}.dmg'
FEED = OUT / 'appcast.xml'
SUMS = OUT / 'SHA256SUMS'
TOOLS = ROOT / '.build-headroom/sparkle-tools/bin'
SPARKLE_NS = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
PUBLIC_URL = f'https://github.com/{REPO}/releases/download/{TAG}/{ZIP.name}'
LEGACY_URL = re.compile(rf'https://api\.github\.com/repos/{re.escape(REPO)}/releases/assets/\d+')


class Failure(RuntimeError):
    pass


def run(*args, **kwargs):
    kwargs.setdefault('check', True)
    return subprocess.run([str(a) for a in args], cwd=ROOT, **kwargs)


def output(*args, **kwargs):
    return run(*args, capture_output=True, text=True, **kwargs).stdout.strip()


def step(message):
    print(f'==> {message}', flush=True)


def sha256(path):
    digest = hashlib.sha256()
    with open(path, 'rb') as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b''):
            digest.update(chunk)
    return digest.hexdigest()


def sign_identity():
    identity = os.environ.get('HEADROOM_SIGN_IDENTITY', '')
    return identity if identity not in ('', '-') else None


def codesign_details(path):
    return run('codesign', '-dv', '--verbose=2', path, capture_output=True, text=True).stderr


# ---------------------------------------------------------------- notarization

def notary_credentials(profile):
    names = ('HEADROOM_NOTARY_KEY', 'HEADROOM_NOTARY_KEY_ID', 'HEADROOM_NOTARY_ISSUER')
    values = [os.environ.get(name, '') for name in names]
    if all(values):
        if not pathlib.Path(values[0]).is_file():
            raise Failure('HEADROOM_NOTARY_KEY must be the path to the App Store Connect .p8 key file.')
        return ['--key', values[0], '--key-id', values[1], '--issuer', values[2]]
    if any(values):
        raise Failure('Set all of ' + ', '.join(names) + ' or none of them.')
    return ['--keychain-profile', profile] if profile else None


def notarize(submission, credentials, staple):
    """Submit `submission` (a ZIP of the app, or the DMG), then staple `staple`."""
    step(f'Notarizing {staple.name} (this waits for Apple)')
    result = json.loads(output('xcrun', 'notarytool', 'submit', submission, *credentials, '--wait', '--timeout', '2h', '--output-format', 'json'))
    (OUT / f'{staple.name}.notarization.json').write_text(json.dumps(result, indent=2) + '\n')
    if result.get('status') != 'Accepted':
        if result.get('id'):
            log = output('xcrun', 'notarytool', 'log', result['id'], *credentials, check=False)
            (OUT / f'{staple.name}.notarization-log.json').write_text(log + '\n')
        raise Failure(f'Apple did not accept {staple.name}: {result.get("status")}. See {OUT}.')
    run('xcrun', 'stapler', 'staple', staple)
    run('xcrun', 'stapler', 'validate', staple)


def is_stapled(path):
    return run('xcrun', 'stapler', 'validate', path, check=False, capture_output=True).returncode == 0


# ------------------------------------------------------------------- packaging

def make_zip():
    ZIP.unlink(missing_ok=True)
    run('ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', APP, ZIP)


def make_dmg():
    DMG.unlink(missing_ok=True)
    with tempfile.TemporaryDirectory() as temp:
        staging = pathlib.Path(temp) / 'root'
        staging.mkdir()
        run('ditto', APP, staging / APP.name)
        (staging / 'Applications').symlink_to('/Applications')
        run('hdiutil', 'create', '-quiet', '-volname', f'{APP_NAME} {VERSION}', '-srcfolder', staging,
            '-fs', 'APFS', '-format', 'ULFO', '-ov', DMG)
    identity = sign_identity()
    if identity:
        keychain = os.environ.get('HEADROOM_SIGN_KEYCHAIN')
        run('codesign', '--force', '--timestamp', '--sign', identity, *(['--keychain', keychain] if keychain else []), DMG)


def write_sums():
    SUMS.write_text(''.join(f'{sha256(path)}  {path.name}\n' for path in (ZIP, DMG)))


def package(args):
    if not APP.is_dir():
        raise Failure(f'{APP} is missing. Run scripts/build.sh first.')
    check_app_info()
    run('codesign', '--verify', '--deep', '--strict', APP)
    OUT.mkdir(parents=True, exist_ok=True)
    credentials = None
    if not args.local:
        if 'Authority=Developer ID Application:' not in codesign_details(APP):
            raise Failure('Distribution needs a Developer ID build: HEADROOM_SIGN_IDENTITY=... scripts/sign.sh (or build.sh). Use --local for a test package.')
        credentials = notary_credentials(args.notary_profile)
        if is_stapled(APP):
            step('App already carries a stapled notarization ticket')
        elif credentials:
            make_zip()  # notarytool takes a ZIP of the app; the final ZIP is rebuilt after stapling
            notarize(ZIP, credentials, APP)
        else:
            raise Failure('App is not notarized. Set HEADROOM_NOTARY_KEY, HEADROOM_NOTARY_KEY_ID and '
                          'HEADROOM_NOTARY_ISSUER, pass --notary-profile, or run scripts/notarize-xcode.py '
                          'upload/export and copy the exported app to dist/ first.')
    step(f'Packaging {ZIP.name}')
    make_zip()
    step(f'Packaging {DMG.name}')
    make_dmg()
    if credentials:
        notarize(DMG, credentials, DMG)
    elif not args.local:
        print(f'warning: {DMG.name} is signed but not notarized (no API key or profile). The app inside is stapled.', file=sys.stderr)
    write_sums()
    print(f'Packaged {OUT}')


# --------------------------------------------------------------------- appcast

def key_source(key_file):
    """sign_update arguments and stdin, plus the private key bytes when known.
    An env secret is piped on stdin so it is never written to disk."""
    secret = os.environ.get('HEADROOM_SPARKLE_ED_KEY', '').strip()
    if key_file:
        return ['--ed-key-file', str(key_file)], None, base64.b64decode(pathlib.Path(key_file).read_text().strip())
    if secret:
        return ['--ed-key-file', '-'], secret, base64.b64decode(secret)
    return ['--account', CONFIG['SPARKLE_KEYCHAIN_ACCOUNT']], None, None


def sign_update(key, *args):
    flags, stdin, _ = key
    if not (TOOLS / 'sign_update').exists():
        raise Failure('Sparkle tools are missing. Run scripts/sparkle-tools.sh first.')
    return run(TOOLS / 'sign_update', *flags, *args, input=stdin, capture_output=True, text=True).stdout.strip()


def public_key_for(key, allow_other_key):
    """The public key signatures must verify against: always the app's own key
    for real releases. A dry run may use a throwaway key."""
    shipped = base64.b64decode(CONFIG['SPARKLE_PUBLIC_ED_KEY'])
    private = key[2]
    if private is None:
        derived = base64.b64decode(output(TOOLS / 'generate_keys', '--account', CONFIG['SPARKLE_KEYCHAIN_ACCOUNT'], '-p'))
    else:
        derived = ed25519.public_key(private)
    if derived != shipped:
        if not allow_other_key:
            raise Failure('The Sparkle signing key does not match SUPublicEDKey in packaging/app.env.')
        print('warning: signing with a key that is NOT the shipped SUPublicEDKey (dry run only).', file=sys.stderr)
    return derived


def notes_html(path):
    sections = []
    for paragraph in path.read_text().strip().split('\n\n'):
        lines = [line for line in paragraph.splitlines() if not line.startswith('#')]
        if not lines:
            continue
        if all(line.startswith('- ') for line in lines):
            sections.append('<ul>' + ''.join('<li>' + html.escape(line[2:]) + '</li>' for line in lines) + '</ul>')
        else:
            sections.append('<p>' + '<br>'.join(html.escape(line) for line in lines) + '</p>')
    body = ''.join(sections).replace(']]>', ']]&gt;')
    return ('<html><head><style>body{font:14px -apple-system,BlinkMacSystemFont,sans-serif;line-height:1.5;'
            'padding:4px 12px}li{margin-bottom:8px}</style></head><body>' + body + '</body></html>')


def write_appcast(key, enclosure_url, notes, allow_other_key=False):
    public = public_key_for(key, allow_other_key)
    signature = sign_update(key, '-p', ZIP)
    if not ed25519.verify(public, ZIP.read_bytes(), base64.b64decode(signature)):
        raise Failure('The ZIP signature does not verify against the expected public key.')
    now = datetime.datetime.now(datetime.timezone.utc).strftime('%a, %d %b %Y %H:%M:%S +0000')
    attr = lambda value: html.escape(value, quote=True)  # noqa: E731
    FEED.write_text(f'''<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="{SPARKLE_NS}">
<channel>
<title>{attr(APP_NAME)} updates</title>
<link>https://github.com/{REPO}</link>
<description>Stable updates for {attr(APP_NAME)}</description>
<item>
<title>{attr(APP_NAME)} {VERSION}</title>
<pubDate>{now}</pubDate>
<link>https://github.com/{REPO}/releases/tag/{TAG}</link>
<sparkle:version>{BUILD}</sparkle:version>
<sparkle:shortVersionString>{VERSION}</sparkle:shortVersionString>
<sparkle:minimumSystemVersion>{CONFIG["MIN_MACOS"]}</sparkle:minimumSystemVersion>
<description><![CDATA[{notes_html(notes)}]]></description>
<enclosure url="{attr(enclosure_url)}" sparkle:installationType="application" sparkle:edSignature="{signature}" length="{ZIP.stat().st_size}" type="application/octet-stream" />
</item>
</channel>
</rss>
''')
    sign_update(key, FEED)
    check_feed(FEED, public)
    print(f'Signed appcast {FEED} -> {enclosure_url}')
    return public


def default_notes():
    return ROOT / 'docs/releases' / f'{TAG}.md'


def appcast(args):
    notes = args.notes or default_notes()
    if not notes.is_file():
        raise Failure(f'Release notes {notes} not found; pass --notes.')
    url = PUBLIC_URL
    if args.legacy_asset_id:
        url = f'https://api.github.com/repos/{REPO}/releases/assets/{int(args.legacy_asset_id)}'
    write_appcast(key_source(args.ed_key_file), url, notes)


# ---------------------------------------------------------------------- checks

def check_app_info(app=APP):
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    expected = {'CFBundleShortVersionString': VERSION, 'CFBundleVersion': BUILD, 'CFBundleIdentifier': CONFIG['BUNDLE_ID'],
                'CFBundleExecutable': CONFIG['EXECUTABLE'], 'LSMinimumSystemVersion': CONFIG['MIN_MACOS'],
                'SUFeedURL': CONFIG['FEED_URL'], 'SUPublicEDKey': CONFIG['SPARKLE_PUBLIC_ED_KEY']}
    wrong = {key: info.get(key) for key, value in expected.items() if info.get(key) != value}
    if wrong or info.get('SURequireSignedFeed') is not True:
        raise Failure(f'{app.name} Info.plist does not match VERSION/app.env: {wrong or "SURequireSignedFeed"}')
    return info


def check_universal(app=APP):
    archs = set(output('lipo', '-archs', app / 'Contents/MacOS' / CONFIG['EXECUTABLE']).split())
    if not {'arm64', 'x86_64'} <= archs:
        raise Failure(f'{app.name} is not universal: {sorted(archs)}')
    return sorted(archs)


def split_feed(data):
    marker = data.rfind(b'<!-- sparkle-signatures:')
    match = re.search(rb'edSignature: ([A-Za-z0-9+/=]+)\s+length: (\d+)', data[marker:]) if marker >= 0 else None
    if not match or int(match.group(2)) != marker:
        raise Failure('appcast.xml has no valid embedded Sparkle signature block.')
    return data[:marker], base64.b64decode(match.group(1))


def check_feed(path, public, zip_path=None):
    """Well-formed, signed by `public`, one item for VERSION/BUILD whose
    enclosure is this release's public download (or the legacy bridge URL)."""
    data = path.read_bytes()
    signed, signature = split_feed(data)
    if not ed25519.verify(public, signed, signature):
        raise Failure(f'{path} feed signature does not verify.')
    items = ET.fromstring(data).findall('./channel/item')
    if len(items) != 1:
        raise Failure('appcast.xml must contain exactly one item.')
    item = items[0]
    ns = {'sparkle': SPARKLE_NS}
    found = (item.findtext('sparkle:version', namespaces=ns), item.findtext('sparkle:shortVersionString', namespaces=ns))
    if found != (BUILD, VERSION):
        raise Failure(f'appcast item is {found}, expected {(BUILD, VERSION)}')
    enclosure = item.find('enclosure')
    url = enclosure.get('url')
    if url != PUBLIC_URL and not LEGACY_URL.fullmatch(url):
        raise Failure(f'Unexpected enclosure URL {url}')
    if enclosure.get(f'{{{SPARKLE_NS}}}installationType') != 'application':
        raise Failure('Enclosure must use sparkle:installationType="application".')
    if zip_path is not None:
        if int(enclosure.get('length')) != zip_path.stat().st_size:
            raise Failure('Enclosure length does not match the ZIP.')
        if not ed25519.verify(public, zip_path.read_bytes(), base64.b64decode(enclosure.get(f'{{{SPARKLE_NS}}}edSignature'))):
            raise Failure('Enclosure edSignature does not verify against the ZIP.')
    return url


@contextlib.contextmanager
def mounted(dmg):
    with tempfile.TemporaryDirectory() as mountpoint:
        run('hdiutil', 'attach', '-quiet', '-nobrowse', '-readonly', '-noautoopen', '-mountpoint', mountpoint, dmg)
        try:
            yield pathlib.Path(mountpoint)
        finally:
            run('hdiutil', 'detach', '-quiet', mountpoint, check=False)


def verify(args, public=None):
    distribution = args.distribution
    public = public or base64.b64decode(args.public_key or CONFIG['SPARKLE_PUBLIC_ED_KEY'])
    report = []
    info = check_app_info()
    report.append(f'app: {info["CFBundleShortVersionString"]} ({info["CFBundleVersion"]}) {info["CFBundleIdentifier"]}, '
                  f'archs {" ".join(check_universal())}')
    run('codesign', '--verify', '--deep', '--strict', APP)
    for line in SUMS.read_text().splitlines():
        digest, name = line.split('  ', 1)
        if sha256(OUT / name) != digest:
            raise Failure(f'SHA256SUMS mismatch for {name}')
    report.append(f'SHA256SUMS: {len(SUMS.read_text().splitlines())} files match')
    with tempfile.TemporaryDirectory() as temp:
        run('ditto', '-x', '-k', ZIP, temp)
        extracted = pathlib.Path(temp) / APP.name
        check_app_info(extracted)
        check_universal(extracted)
        run('codesign', '--verify', '--deep', '--strict', extracted)
        report.append(f'zip: {ZIP.name} extracts {APP.name} with a valid signature')
    with mounted(DMG) as volume:
        entries = sorted(p.name for p in volume.iterdir() if not p.name.startswith('.'))
        link = volume / 'Applications'
        if entries != sorted([APP.name, 'Applications']) or not link.is_symlink() or os.readlink(link) != '/Applications':
            raise Failure(f'DMG layout is wrong: {entries}')
        check_app_info(volume / APP.name)
        check_universal(volume / APP.name)
        run('codesign', '--verify', '--deep', '--strict', volume / APP.name)
        report.append(f'dmg: {DMG.name} mounts with {", ".join(entries)} -> /Applications')
    url = check_feed(FEED, public, ZIP)
    report.append(f'appcast: well-formed, feed + archive signatures verify, enclosure {url}')
    if distribution:
        for path in (APP, DMG):
            if 'Authority=Developer ID Application:' not in codesign_details(path):
                raise Failure(f'{path.name} is not Developer ID signed.')
        run('xcrun', 'stapler', 'validate', APP)
        run('spctl', '--assess', '--type', 'execute', '--verbose=2', APP)
        if is_stapled(DMG):
            run('spctl', '--assess', '--type', 'open', '--context', 'context:primary-signature', '--verbose=2', DMG)
        report.append('distribution: Developer ID, stapled, Gatekeeper accepts the app')
    print('\n'.join('ok  ' + line for line in report))


# ------------------------------------------------------------------- dry run

def dry_run(args):
    notes = args.notes or default_notes()
    with tempfile.TemporaryDirectory() as temp:
        if not notes.is_file():
            notes = pathlib.Path(temp) / 'notes.md'
            notes.write_text(f'Dry run of {APP_NAME} {VERSION}.\n\n- Local packaging check.\n')
        package(argparse.Namespace(local=True, notary_profile=None))
        key_file = args.ed_key_file
        if key_file is None:
            key_file = pathlib.Path(temp) / 'throwaway-ed25519.key'
            key_file.write_text(base64.b64encode(os.urandom(32)).decode())
            key_file.chmod(0o600)
        public = write_appcast(key_source(key_file), PUBLIC_URL, notes, allow_other_key=True)
    verify(argparse.Namespace(distribution=False, public_key=None), public=public)
    cask = run('/usr/bin/python3', ROOT / 'scripts/render-cask.py', '--dmg', DMG, capture_output=True, text=True).stdout.strip()
    print(f'ok  cask: {cask}')
    print(f'Dry run complete: {OUT}')


# --------------------------------------------------------------------- GitHub

def gh_release(*args):
    return output('gh', 'release', *args, '--repo', REPO)


def find_release():
    """Includes drafts, which `releases/tags/<tag>` does not return."""
    releases = json.loads(output('gh', 'api', f'repos/{REPO}/releases?per_page=100'))
    return next((r for r in releases if r['tag_name'] == TAG), None)


def publish(args):
    for path in (ZIP, DMG, SUMS):
        if not path.is_file():
            raise Failure(f'{path} is missing; run package first.')
    notes = args.notes or default_notes()
    release = find_release()
    if release and not release['draft']:
        raise Failure(f'{TAG} is already published; bump VERSION.')
    # CI releases the pushed tag; a local publisher targets HEAD and GitHub creates the tag on publish.
    target = [] if args.verify_tag else ['--target', output('git', 'rev-parse', 'HEAD')]
    if release:
        gh_release('edit', TAG, *target, '--notes-file', notes)
    else:
        gh_release('create', TAG, '--draft', *(target or ['--verify-tag']), '--title', f'{APP_NAME} {VERSION}', '--notes-file', notes)
    gh_release('upload', TAG, ZIP, DMG, SUMS, '--clobber')
    if args.legacy_bridge:
        asset = next(a for a in find_release()['assets'] if a['name'] == ZIP.name)
        step(f'Bridge feed for pre-public builds: enclosure uses API asset {asset["id"]}')
        write_appcast(key_source(args.ed_key_file), f'https://api.github.com/repos/{REPO}/releases/assets/{int(asset["id"])}', notes)
    elif not FEED.is_file():
        raise Failure(f'{FEED} is missing; run appcast first.')
    check_feed(FEED, base64.b64decode(CONFIG['SPARKLE_PUBLIC_ED_KEY']), ZIP)
    gh_release('upload', TAG, FEED, '--clobber')
    print(f'Draft {TAG} ready: {find_release()["html_url"]}')
    print(f'Next: review it, publish it (gh release edit {TAG} --draft=false --latest --repo {REPO}),')
    print('then run scripts/release.py promote and commit appcast.xml to main.')


def promote(args):
    """Ship the update: copy a verified feed into the repo after the release is public."""
    public = base64.b64decode(CONFIG['SPARKLE_PUBLIC_ED_KEY'])
    source = FEED
    with tempfile.TemporaryDirectory() as temp:
        if args.from_release:
            source = pathlib.Path(temp) / 'appcast.xml'
            urllib.request.urlretrieve(f'https://github.com/{REPO}/releases/download/{TAG}/appcast.xml', source)
        url = check_feed(source, public)
        length = int(ET.fromstring(source.read_bytes()).find('./channel/item/enclosure').get('length'))
        if args.no_download_check:
            print('warning: not checking that the enclosure is publicly downloadable.', file=sys.stderr)
        else:
            request = urllib.request.Request(url, method='HEAD', headers={'Accept': 'application/octet-stream'})
            with urllib.request.urlopen(request, timeout=30) as response:  # follows GitHub's storage redirect
                if int(response.headers.get('Content-Length', -1)) != length:
                    raise Failure(f'{url} is not publicly downloadable with the expected length yet. Publish the release first.')
        (ROOT / 'appcast.xml').write_bytes(source.read_bytes())
    print(f'appcast.xml now offers {VERSION} ({BUILD}) from {url}')
    print('Commit it byte-for-byte to main (directly or via a PR); clients see it once it lands on main.')


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest='command', required=True)
    for name in ('dry-run', 'package', 'appcast', 'verify', 'publish', 'promote'):
        sub = commands.add_parser(name)
        if name in ('dry-run', 'appcast', 'publish'):
            sub.add_argument('--notes', type=pathlib.Path, help='Markdown-ish notes (default docs/releases/<tag>.md)')
            sub.add_argument('--ed-key-file', type=pathlib.Path, help='Sparkle private key file (default: env or Keychain)')
        if name == 'package':
            sub.add_argument('--local', action='store_true', help='Any signature, no notarization (testing only)')
            sub.add_argument('--notary-profile', help='notarytool Keychain profile when no API key env is set')
        if name == 'appcast':
            sub.add_argument('--legacy-asset-id', type=int, help='Bridge: enclose the API asset URL old private builds accept')
        if name == 'verify':
            sub.add_argument('--distribution', action='store_true', help='Also require Developer ID, stapling, Gatekeeper')
            sub.add_argument('--public-key', help='Verify against this base64 key instead of SUPublicEDKey')
        if name == 'publish':
            sub.add_argument('--legacy-bridge', action='store_true', help='Point the feed at the API asset URL (first public release only)')
            sub.add_argument('--verify-tag', action='store_true', help='Use the pushed tag instead of HEAD (CI)')
        if name == 'promote':
            sub.add_argument('--from-release', action='store_true', help='Use the appcast.xml attached to the published release')
            sub.add_argument('--no-download-check', action='store_true',
                             help='Skip the anonymous download check (a legacy-bridge feed while the repo is still private)')
    args = parser.parse_args()
    {'dry-run': dry_run, 'package': package, 'appcast': appcast, 'verify': verify,
     'publish': publish, 'promote': promote}[args.command](args)


if __name__ == '__main__':
    try:
        main()
    except (Failure, ValueError, subprocess.CalledProcessError, OSError) as error:
        detail = getattr(error, 'stderr', None)
        print(f'Release step failed: {error}' + (f'\n{detail.strip()}' if detail else ''), file=sys.stderr)
        sys.exit(1)
