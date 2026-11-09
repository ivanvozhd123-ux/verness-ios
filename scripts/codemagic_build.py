"""Build a device IPA on Codemagic's Mac, retaining the Island extension."""
import argparse
import hashlib
import json
import os
import platform
import plistlib
import shutil
import subprocess
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "build/ios/ipa"
LOGS = ROOT / "build/ios/logs"


def run(command, name):
    LOGS.mkdir(parents=True, exist_ok=True)
    with (LOGS / (name + ".log")).open("w", encoding="utf-8") as log:
        process = subprocess.Popen(command, cwd=ROOT, stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT, text=True)
        for line in process.stdout:
            print(line, end="", flush=True)
            log.write(line)
        if process.wait():
            raise RuntimeError(f"{name} failed; see build/ios/logs/{name}.log")


def device_bundle(app):
    with (app / "Info.plist").open("rb") as file:
        info = plistlib.load(file)
    if info.get("CFBundleSupportedPlatforms") != ["iPhoneOS"]:
        raise ValueError(f"Expected iPhone device bundle, not simulator: {app.name}")
    executable = info["CFBundleExecutable"]
    if Path(executable).name != executable or not (app / executable).is_file():
        raise ValueError("Invalid or missing bundle executable")
    return info


def package_unsigned(app, destination):
    info = device_bundle(app)
    extension = app / "PlugIns/VernessIsland.appex"
    extension_info = device_bundle(extension)
    if extension_info["CFBundleIdentifier"] != info["CFBundleIdentifier"] + ".island":
        raise ValueError("Island bundle identifier does not match the application")
    destination.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(destination, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for file in sorted(app.rglob("*")):
            if file.is_file():
                # zipfile preserves Unix executable permissions from the macOS build.
                archive.write(file, "Payload/" + app.name + "/" + file.relative_to(app).as_posix())
    return info


def write_metadata(ipa, signed):
    digest = hashlib.sha256(ipa.read_bytes()).hexdigest()
    ipa.with_suffix(".ipa.sha256").write_text(f"{digest}  {ipa.name}\n", encoding="utf-8")
    data = {"filename": ipa.name, "sha256": digest, "bytes": ipa.stat().st_size,
            "signed": signed, "platform": "iphoneos", "island_included": True,
            "commit": os.environ.get("CM_COMMIT", ""),
            "build_number": os.environ.get("BUILD_NUMBER", "local"),
            "installation": "Ad Hoc provisioned devices only" if signed else "Requires signing before installation"}
    ipa.with_name(ipa.stem + "-build-info.json").write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("unsigned", "signed"))
    args = parser.parse_args()
    if platform.system() != "Darwin" or not shutil.which("xcodebuild"):
        parser.error("Run this on a macOS Codemagic builder with Xcode, not on Windows")
    OUTPUT.mkdir(parents=True, exist_ok=True)
    run(["xcodebuild", "-version"], "xcode-version")
    if args.mode == "signed":
        run(["xcode-project", "use-profiles", "--project", "verness.xcodeproj"], "signing")
        run(["xcode-project", "build-ipa", "--project", "verness.xcodeproj",
             "--scheme", "verness", "--config", "Release"], "signed-archive")
        packages = list(OUTPUT.glob("*.ipa"))
        if len(packages) != 1:
            raise RuntimeError("Expected exactly one exported signed IPA")
        ipa = packages[0]
        with zipfile.ZipFile(ipa) as archive:
            required = ["Payload/verness.app/embedded.mobileprovision",
                        "Payload/verness.app/PlugIns/VernessIsland.appex/embedded.mobileprovision"]
            if not all(name in archive.namelist() for name in required):
                raise RuntimeError("Signed IPA is missing app or Island provisioning profile")
        write_metadata(ipa, signed=True)
    else:
        archive = ROOT / "build/ios/archive/verness.xcarchive"
        run(["xcodebuild", "-project", "verness.xcodeproj", "-scheme", "verness",
             "-configuration", "Release", "-sdk", "iphoneos", "-destination", "generic/platform=iOS",
             "-archivePath", str(archive), "-derivedDataPath", str(ROOT / "build/DerivedData"),
             "CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_REQUIRED=NO", "CODE_SIGN_IDENTITY=", "archive"], "unsigned-archive")
        app = archive / "Products/Applications/verness.app"
        for bundle in (app, app / "PlugIns/VernessIsland.appex"):
            info = device_bundle(bundle)
            run(["xcrun", "lipo", str(bundle / info["CFBundleExecutable"]), "-verify_arch", "arm64"], bundle.stem + "-architecture")
        with (app / "Info.plist").open("rb") as file:
            version = plistlib.load(file)["CFBundleShortVersionString"]
        ipa = OUTPUT / f"verness-ios-{version}-unsigned.ipa"
        package_unsigned(app, ipa)
        write_metadata(ipa, signed=False)
        print("UNSIGNED IPA: signing is required before installation on an iPhone.")
    print(f"IPA artifact: {ipa}")


if __name__ == "__main__":
    main()
