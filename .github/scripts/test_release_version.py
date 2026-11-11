import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

from set_release_version import sync_version


class ReleaseVersionTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="picacomic-version-")
        self.root = Path(self.directory.name).resolve()
        self.assertTrue(self.root.is_relative_to(Path(tempfile.gettempdir()).resolve()))
        self.addCleanup(self.directory.cleanup)
        (self.root / "lib/foundation").mkdir(parents=True)
        self.pubspec = self.root / "pubspec.yaml"
        self.definitions = self.root / "lib/foundation/def.dart"
        self.pubspec.write_bytes(b"name: pica_comic\r\nversion: 4.2.11+4211\r\n")
        self.definitions.write_bytes(
            b'// App version\r\nconst appVersion = "4.2.11";\r\n'
            b'const comicSourceApiVersion = "4.2.11";\r\n'
        )

    def test_release_tag_updates_native_and_display_versions(self):
        self.assertEqual(sync_version(self.root, "v1.0.0"), "1.0.0")
        self.assertEqual(self.pubspec.read_bytes(), b"name: pica_comic\r\nversion: 1.0.0+4211\r\n")
        self.assertIn(b'const appVersion = "1.0.0";\r\n', self.definitions.read_bytes())

    def test_future_tags_and_repeated_runs_replace_the_previous_version(self):
        for tag in ("v1.0.0", "2.10.3", "v12.0.8", "v12.0.8"):
            version = tag.removeprefix("v")
            self.assertEqual(sync_version(self.root, tag), version)
            self.assertIn(f"version: {version}+4211", self.pubspec.read_text())
            self.assertIn(f'const appVersion = "{version}";', self.definitions.read_text())

    def test_release_tags_do_not_change_comic_source_api_compatibility(self):
        for tag in ("v1.0.0", "v1.2.3", "v5.0.0"):
            sync_version(self.root, tag)
            self.assertIn(
                'const comicSourceApiVersion = "4.2.11";', self.definitions.read_text()
            )

    def test_invalid_tags_leave_both_files_unchanged(self):
        original = (self.pubspec.read_bytes(), self.definitions.read_bytes())
        for tag in ("latest", "v1", "v1.2", "v01.2.3", "v1.2.3-beta.1", "v1.2.3+4", "v1.2.3\n", "release/v1.2.3"):
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                sync_version(self.root, tag)
            self.assertEqual((self.pubspec.read_bytes(), self.definitions.read_bytes()), original)

    def test_missing_display_version_does_not_partially_update_pubspec(self):
        original = self.pubspec.read_bytes()
        self.definitions.write_text("// missing version\n", encoding="utf-8")
        with self.assertRaises(ValueError):
            sync_version(self.root, "v1.0.0")
        self.assertEqual(self.pubspec.read_bytes(), original)

    def test_version_without_a_build_number(self):
        self.pubspec.write_text("version: 4.2.11\n", encoding="utf-8")
        sync_version(self.root, "v0.0.1")
        self.assertEqual(self.pubspec.read_text(), "version: 0.0.1\n")

    def test_pubspec_version_comment_is_preserved(self):
        self.pubspec.write_text("version: 4.2.11+4211  # build number\n", encoding="utf-8")
        sync_version(self.root, "v1.0.1")
        self.assertEqual(self.pubspec.read_text(), "version: 1.0.1+4211  # build number\n")

    def test_workflow_command_exports_the_same_version(self):
        script = self.root / ".github/scripts/set_release_version.py"
        script.parent.mkdir(parents=True)
        shutil.copyfile(Path(__file__).with_name("set_release_version.py"), script)
        environment_file = self.root / "github-env"
        result = subprocess.run(
            [sys.executable, str(script), "v3.2.1"],
            env={**os.environ, "GITHUB_ENV": str(environment_file)},
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(environment_file.read_text(), "APP_VERSION=3.2.1\n")
        self.assertIn("version: 3.2.1+4211", self.pubspec.read_text())
        self.assertIn('const appVersion = "3.2.1";', self.definitions.read_text())


if __name__ == "__main__":
    unittest.main()
