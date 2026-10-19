"""Regression checks for the release packager; no Android SDK is required."""

import hashlib
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import zipfile


class PackageReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.android = self.root / "android"
        scripts = self.android / "scripts"
        scripts.mkdir(parents=True)
        shutil.copyfile(Path(__file__).with_name("package-release.sh"), scripts / "package-release.sh")
        (self.root / "LICENSE").write_text("Test license notice\n")
        (self.android / "README.md").write_text("Installation instructions\n")
        self.version = "0.1.0"
        (self.android / "CHANGELOG.md").write_text(f"# Changelog\n\n## {self.version}\n\n- Release notes\n")
        self.gradle = self.android / "moby-beacon/build.gradle"
        self.gradle.parent.mkdir(parents=True)
        self.gradle.write_text(f"group = 'com.mobyinc'\nversion = '{self.version}'\n")
        self.kotlin = self.android / "moby-beacon/src/main/java/com/mobyinc/beacon/MobyBeacon.kt"
        self.kotlin.parent.mkdir(parents=True)
        self.kotlin.write_text(f'class MobyBeacon {{\n    companion object {{\n        const val VERSION = "{self.version}"\n    }}\n}}\n')
        self.name = f"moby-beacon-{self.version}"
        self.publication = self.android / "moby-beacon/build/repo/com/mobyinc/moby-beacon" / self.version
        self.publication.mkdir(parents=True)
        self.artifacts = [
            f"{self.name}.aar",
            f"{self.name}.pom",
            f"{self.name}.module",
            f"{self.name}-sources.jar",
        ]
        for artifact in self.artifacts:
            (self.publication / artifact).write_bytes(f"published {artifact}\n".encode())
        self.output = self.android / "build/release"

    def package(self):
        # Run outside android/ to exercise script-relative paths as clients do.
        return subprocess.run(
            ["bash", str(self.android / "scripts/package-release.sh"), self.version],
            cwd=self.root,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

    def test_packages_complete_publication_and_matching_checksum(self):
        result = self.package()
        self.assertEqual(result.returncode, 0, result.stderr)
        archive = self.output / f"{self.name}.zip"
        with zipfile.ZipFile(archive) as package:
            for artifact in self.artifacts:
                name = f"{self.name}/repo/com/mobyinc/moby-beacon/{self.version}/{artifact}"
                self.assertEqual(package.read(name), (self.publication / artifact).read_bytes())
            self.assertIn(f"{self.name}/LICENSE", package.namelist())
            self.assertEqual(package.read(f"{self.name}/LICENSE"), (self.root / "LICENSE").read_bytes())
        checksum = (self.output / f"{self.name}.zip.sha256").read_text().split()[0]
        self.assertEqual(checksum, hashlib.sha256(archive.read_bytes()).hexdigest())

    def test_rejects_missing_artifacts_without_replacing_previous_release(self):
        previous = self.output / self.name
        previous.mkdir(parents=True)
        marker = previous / "previous-release"
        marker.write_text("keep me")
        archive = self.output / f"{self.name}.zip"
        archive.write_bytes(b"previous archive")
        for artifact in self.artifacts:
            with self.subTest(artifact=artifact):
                path = self.publication / artifact
                contents = path.read_bytes()
                path.unlink()
                result = self.package()
                path.write_bytes(contents)
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertIn(artifact, result.stderr)
                self.assertEqual(marker.read_text(), "keep me")
                self.assertEqual(archive.read_bytes(), b"previous archive")

    def test_rejects_empty_artifacts(self):
        for artifact in self.artifacts:
            with self.subTest(artifact=artifact):
                path = self.publication / artifact
                contents = path.read_bytes()
                path.write_bytes(b"")
                result = self.package()
                path.write_bytes(contents)
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertIn(artifact, result.stderr)

    def test_rejects_version_not_declared_in_sources_without_replacing_previous_release(self):
        previous = self.output / self.name
        previous.mkdir(parents=True)
        marker = previous / "previous-release"
        marker.write_text("keep me")
        stale = [
            (self.gradle, "version = '0.1.0'", "version = '0.2.0'"),
            (self.kotlin, 'VERSION = "0.1.0"', 'VERSION = "0.2.0"'),
            (self.android / "CHANGELOG.md", "## 0.1.0", "## 0.2.0"),
        ]
        for path, current, bumped in stale:
            with self.subTest(file=path.name):
                contents = path.read_text()
                path.write_text(contents.replace(current, bumped))
                result = self.package()
                path.write_text(contents)
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertIn(path.name, result.stderr)
                self.assertIn("0.1.0", result.stderr)
                self.assertEqual(marker.read_text(), "keep me")


if __name__ == "__main__":
    unittest.main()
