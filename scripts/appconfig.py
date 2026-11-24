#!/usr/bin/python3
"""Read packaging/app.env and VERSION, and render @KEY@ templates from them.

    appconfig.py get KEY
    appconfig.py render TEMPLATE OUTPUT [KEY=VALUE ...]

Both files are plain KEY=VALUE lines so zsh can `source` them too.
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
FILES = (ROOT / 'packaging/app.env', ROOT / 'VERSION')
REQUIRED = ('APP_NAME', 'EXECUTABLE', 'BUNDLE_ID', 'MIN_MACOS', 'GITHUB_REPO', 'FEED_URL',
            'SPARKLE_PUBLIC_ED_KEY', 'SPARKLE_KEYCHAIN_ACCOUNT', 'MARKETING_VERSION', 'BUILD_NUMBER')
PLACEHOLDER = re.compile(r'@([A-Z][A-Z0-9_]*)@')


def parse(path):
    values = {}
    for number, line in enumerate(path.read_text().splitlines(), 1):
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        key, sep, value = line.partition('=')
        if not sep or not re.fullmatch(r'[A-Z][A-Z0-9_]*', key) or re.search(r'[\s"\'$`\\]', value):
            raise ValueError(f'{path.name}:{number}: expected KEY=VALUE without quotes, spaces or $')
        values[key] = value
    return values


def load():
    config = {}
    for path in FILES:
        config.update(parse(path))
    missing = [key for key in REQUIRED if not config.get(key)]
    if missing:
        raise ValueError('Missing config values: ' + ', '.join(missing))
    if not re.fullmatch(r'\d+\.\d+\.\d+', config['MARKETING_VERSION']):
        raise ValueError('MARKETING_VERSION must look like 1.2.3')
    if not re.fullmatch(r'[1-9]\d*', config['BUILD_NUMBER']):
        raise ValueError('BUILD_NUMBER must be a positive integer')
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', config['GITHUB_REPO']):
        raise ValueError('GITHUB_REPO must be owner/name')
    config['TAG'] = 'v' + config['MARKETING_VERSION']
    return config


def render(text, values):
    def substitute(match):
        if match.group(1) not in values:
            raise ValueError(f'No value for template placeholder {match.group(0)}')
        return values[match.group(1)]
    return PLACEHOLDER.sub(substitute, text)


def main(argv):
    config = load()
    if len(argv) == 2 and argv[0] == 'get':
        print(config[argv[1]])
    elif len(argv) >= 3 and argv[0] == 'render':
        extra = dict(item.split('=', 1) for item in argv[3:])
        output = render(pathlib.Path(argv[1]).read_text(), {**config, **extra})
        pathlib.Path(argv[2]).write_text(output)
    else:
        sys.exit(__doc__)


if __name__ == '__main__':
    try:
        main(sys.argv[1:])
    except (KeyError, ValueError, OSError) as error:
        sys.exit(f'appconfig: {error}')
