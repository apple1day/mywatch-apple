#!/usr/bin/env python3
"""Regression checks for preserving all app/test signing configurations."""
import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("preserve", Path(__file__).with_name("preserve-signing.py"))
preserve = importlib.util.module_from_spec(spec)
spec.loader.exec_module(preserve)


class SigningPreservationTests(unittest.TestCase):
    def test_app_and_both_test_targets_keep_separate_settings(self):
        objects = {}
        for index, name in enumerate(sorted(preserve.TARGETS)):
            objects[name] = {"isa": "PBXNativeTarget", "name": name, "buildConfigurationList": name + "-configs"}
            objects[name + "-configs"] = {"buildConfigurations": [name + "-Debug", name + "-Release"]}
            for config in ("Debug", "Release"):
                objects[name + "-" + config] = {"name": config, "buildSettings": {
                    "DEVELOPMENT_TEAM": f"TEAM{index}",
                    "PRODUCT_BUNDLE_IDENTIFIER": f"example.{name}.{config}",
                    "PROVISIONING_PROFILE_SPECIFIER[sdk=iphoneos*]": f"Profile {name} {config}",
                    "SWIFT_VERSION": "5.0",
                }}
        extracted = preserve.extract_overrides({"objects": objects})
        self.assertEqual(len(extracted), 6)
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            self.assertEqual(preserve.write_overlays(root, extracted), 6)
            for (name, config), settings in extracted.items():
                text = (root / f"{name}.{config}.local.xcconfig").read_text()
                self.assertIn(f'PRODUCT_BUNDLE_IDENTIFIER = "example.{name}.{config}"', text)
                self.assertIn(f'"Profile {name} {config}"', text)
                self.assertNotIn("SWIFT_VERSION", text)
            self.assertEqual(preserve.write_overlays(root, extracted), 0)

    def test_inherited_settings_leave_existing_overlays_unchanged(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            old = root / "WatchLink.Debug.local.xcconfig"
            old.write_text('DEVELOPMENT_TEAM = "PERSONAL"\n')
            preserve.write_overlays(root, {})
            self.assertEqual(old.read_text(), 'DEVELOPMENT_TEAM = "PERSONAL"\n')

    def test_explicit_clear_is_preserved(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            old = root / "WatchLink.Debug.local.xcconfig"
            old.write_text('PROVISIONING_PROFILE_SPECIFIER = "Old profile"\n')
            preserve.write_overlays(root, {("WatchLink", "Debug"): {"PROVISIONING_PROFILE_SPECIFIER": '""'}})
            self.assertIn('PROVISIONING_PROFILE_SPECIFIER = ""', old.read_text())
            self.assertNotIn("Old profile", old.read_text())


if __name__ == "__main__":
    unittest.main()
