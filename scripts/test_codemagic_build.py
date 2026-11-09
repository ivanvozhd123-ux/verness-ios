import plistlib
import tempfile
import unittest
import zipfile
from pathlib import Path

from codemagic_build import package_unsigned


class PackagingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.app = self.root / "verness.app"
        self.extension = self.app / "PlugIns/VernessIsland.appex"
        for bundle, identifier in ((self.app, "app.verness.ios"), (self.extension, "app.verness.ios.island")):
            bundle.mkdir(parents=True, exist_ok=True)
            (bundle / "Info.plist").write_bytes(plistlib.dumps({
                "CFBundleIdentifier": identifier, "CFBundleExecutable": bundle.stem,
                "CFBundleSupportedPlatforms": ["iPhoneOS"]}))
            # These are fixture bytes, never a real application or release artifact.
            (bundle / bundle.stem).write_bytes(b"fixture")

    def test_payload_preserves_island(self):
        output = self.root / "test.ipa"
        package_unsigned(self.app, output)
        with zipfile.ZipFile(output) as archive:
            self.assertIn("Payload/verness.app/verness", archive.namelist())
            self.assertIn("Payload/verness.app/PlugIns/VernessIsland.appex/VernessIsland", archive.namelist())
            self.assertIsNone(archive.testzip())

    def test_rejects_simulator(self):
        path = self.app / "Info.plist"
        data = plistlib.loads(path.read_bytes())
        data["CFBundleSupportedPlatforms"] = ["iPhoneSimulator"]
        path.write_bytes(plistlib.dumps(data))
        with self.assertRaises(ValueError):
            package_unsigned(self.app, self.root / "test.ipa")

    def test_rejects_missing_extension_executable(self):
        (self.extension / "VernessIsland").unlink()
        with self.assertRaises(ValueError):
            package_unsigned(self.app, self.root / "test.ipa")


if __name__ == "__main__":
    unittest.main()
