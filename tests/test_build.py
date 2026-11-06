"""Offline CLI safety and Steam library discovery regression checks."""
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("tfm2pad_build", Path(__file__).resolve().parents[1] / "scripts/build.py")
build = importlib.util.module_from_spec(spec)
spec.loader.exec_module(build)


class DiscoveryTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.home = Path(self.directory.name)
        self.primary = self.home / "Library/Application Support/Steam"

    def game(self, library, directory="Teamfight Manager2"):
        steamapps = library / "steamapps"
        steamapps.mkdir(parents=True, exist_ok=True)
        (steamapps / "appmanifest_3009300.acf").write_text(
            '"AppState" { "appid" "3009300" "installdir" "' + directory + '" }')
        app = steamapps / "common" / directory / "TeamfightManager2.app"
        app.mkdir(parents=True)
        return app.resolve()

    def test_external_library_with_spaces_is_discovered_without_account_files(self):
        external = self.home / "External Library"
        expected = self.game(external)
        (self.primary / "steamapps").mkdir(parents=True)
        (self.primary / "steamapps/libraryfolders.vdf").write_text(
            '"libraryfolders" { "0" { "path" "' + str(self.primary) + '" } "1" { "path" "' + str(external) + '" } }')
        before = sorted(str(p) for p in self.home.rglob("*"))
        self.assertEqual(build.discover_game(build.steam_libraries(self.home)), expected)
        self.assertEqual(sorted(str(p) for p in self.home.rglob("*")), before)

    def test_multiple_owned_copies_require_explicit_selection(self):
        self.game(self.primary)
        external = self.home / "Second Library"
        self.game(external)
        with self.assertRaisesRegex(build.BuildError, "Multiple game installations"):
            build.discover_game([self.primary, external])

    def test_manifest_cannot_escape_common_directory(self):
        steamapps = self.primary / "steamapps"
        steamapps.mkdir(parents=True)
        (steamapps / "appmanifest_3009300.acf").write_text(
            '"AppState" { "appid" "3009300" "installdir" "../../escape" }')
        with self.assertRaisesRegex(build.BuildError, "invalid installation directory"):
            build.discover_game([self.primary])


class BuildSafetyTests(unittest.TestCase):
    def test_changed_game_blocks_before_reading_steam_or_creating_work(self):
        with tempfile.TemporaryDirectory() as directory:
            missing = Path(directory) / "does-not-exist"
            with patch.object(build.portkit, "observe", return_value={}), \
                    patch.object(build.portkit, "differences", return_value=["files.game.sha256"]), \
                    patch.object(build, "read_json", return_value={}):
                with self.assertRaisesRegex(build.BuildError, "Unsupported or changed game"):
                    build.checked_inputs(missing, missing)
            self.assertEqual(list(Path(directory).iterdir()), [])

    def test_explicit_developer_directory_is_preserved(self):
        with patch.dict(os.environ, {"DEVELOPER_DIR": "/custom/Xcode.app/Contents/Developer"}), \
                patch.object(build, "capture", side_effect=AssertionError("must not select another Xcode")):
            self.assertEqual(build.developer_environment()["DEVELOPER_DIR"], "/custom/Xcode.app/Contents/Developer")

    def test_existing_build_and_outside_output_are_preserved(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            work = root / "work"
            work.mkdir()
            existing = work / "existing"
            existing.mkdir()
            sentinel = existing / "keep.txt"
            sentinel.write_text("keep")
            for output in (existing, root / "outside"):
                args = build.parser().parse_args(["build", "--output", str(output)])
                with patch.object(build, "WORK", work), \
                        patch.object(build, "source_paths", return_value=(root / "game.app", root / "steam")), \
                        patch.object(build, "checked_inputs", return_value={}), \
                        patch.object(build, "doctor", return_value={"ok": True}), \
                        patch.object(build, "run_step", side_effect=AssertionError("must not build")):
                    with self.assertRaises(build.BuildError):
                        build.build(args)
                self.assertEqual(sentinel.read_text(), "keep")
                self.assertFalse((root / "outside").exists())

    def test_offline_missing_tools_never_runs_pip(self):
        with patch.object(build.shutil, "which", return_value=None), \
                patch.object(build.subprocess, "run", side_effect=AssertionError("must not download")):
            with self.assertRaisesRegex(build.BuildError, "offline mode"):
                build.bootstrap_tools({"PATH": ""}, offline=True)


if __name__ == "__main__":
    unittest.main()
