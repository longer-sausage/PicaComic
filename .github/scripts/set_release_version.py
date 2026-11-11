"""Use a release tag as the version of every platform and the in-app UI."""

import argparse
import os
from pathlib import Path
import re


def sync_version(root: Path, tag: str) -> str:
    match = re.fullmatch(r"v?((?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*))", tag)
    if match is None:
        raise ValueError("Release tags must use vMAJOR.MINOR.PATCH or MAJOR.MINOR.PATCH")
    version = match.group(1)

    pubspec_path = root / "pubspec.yaml"
    definitions_path = root / "lib/foundation/def.dart"
    pubspec = pubspec_path.read_bytes().decode("utf-8")
    definitions = definitions_path.read_bytes().decode("utf-8")

    version_pattern = re.compile(r"(?m)^(version:[ \t]*)([^\s#]+)([ \t]*)(?=#|\r?$)")
    versions = list(version_pattern.finditer(pubspec))
    if len(versions) != 1:
        raise ValueError("pubspec.yaml must contain exactly one top-level version")
    current = versions[0].group(2)
    _, separator, build_number = current.partition("+")
    if separator and not re.fullmatch(r"[0-9]+", build_number):
        raise ValueError("The pubspec build number must be an integer")
    suffix = f"+{build_number}" if separator else ""
    pubspec = version_pattern.sub(
        lambda match: f"{match.group(1)}{version}{suffix}{match.group(3)}", pubspec
    )

    definitions, count = re.subn(
        r'(?m)^const appVersion = "[^"\r\n]*";',
        f'const appVersion = "{version}";',
        definitions,
    )
    if count != 1:
        raise ValueError("def.dart must contain exactly one appVersion constant")

    # Validate both inputs before changing either file. Keep existing line endings.
    pubspec_path.write_bytes(pubspec.encode("utf-8"))
    definitions_path.write_bytes(definitions.encode("utf-8"))
    return version


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("tag", help="Release tag, for example v1.0.0")
    args = parser.parse_args()
    try:
        version = sync_version(Path(__file__).resolve().parents[2], args.tag)
    except (OSError, ValueError) as error:
        parser.exit(1, f"Version synchronization failed: {error}\n")
    if environment_file := os.environ.get("GITHUB_ENV"):
        with open(environment_file, "a", encoding="utf-8") as output:
            output.write(f"APP_VERSION={version}\n")
    print(f"Application version: {version} (tag: {args.tag})")


if __name__ == "__main__":
    main()
