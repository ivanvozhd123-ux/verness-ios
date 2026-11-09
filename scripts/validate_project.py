import argparse
import json
import plistlib
import re
import struct
import sys
from pathlib import Path
from xml.etree import ElementTree

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument("--parser-tools", type=Path, help="Optional tree-sitter and openstep-parser module directory")
args = parser.parse_args()
pbx = (root / "verness.xcodeproj/project.pbxproj").read_text(encoding="utf-8")
definitions = re.findall(r"^\s*([A-F0-9]{24}) = \{", pbx, re.M)
assert len(definitions) == len(set(definitions)), "Duplicate Xcode object IDs"
references = set(re.findall(r"\b[A-F0-9]{24}\b", pbx))
assert references <= set(definitions), "Missing Xcode object references"
for path in re.findall(r'path = "([^"]+)"; sourceTree = SOURCE_ROOT;', pbx):
    assert (root / path).exists(), path
for path in (root / "App/Info.plist", root / "Island/Info.plist"):
    with path.open("rb") as file:
        plistlib.load(file)
for path in root.rglob("Contents.json"):
    data = json.loads(path.read_text(encoding="utf-8"))
    for image in data.get("images", []):
        if "filename" in image:
            assert (path.parent / image["filename"]).exists(), image["filename"]
icon = (root / "App/Assets.xcassets/AppIcon.appiconset/AppIcon.png").read_bytes()
assert icon[:8] == b"\x89PNG\r\n\x1a\n" and struct.unpack(">II", icon[16:24]) == (1024, 1024)
assert icon[25] in (0, 2), "App icon must not have an alpha channel"
ElementTree.parse(root / "verness.xcodeproj/xcshareddata/xcschemes/verness.xcscheme")
print("PASS Xcode references, app/extension plists, shared scheme and 1024px app icon")
if args.parser_tools:
    sys.path.insert(0, str(args.parser_tools))
    from tree_sitter import Language, Parser
    import tree_sitter_swift
    from openstep_parser import OpenStepDecoder
    OpenStepDecoder.ParseFromString(pbx)
    grammar = Parser(Language(tree_sitter_swift.language()))
    for path in root.rglob("*.swift"):
        tree = grammar.parse(path.read_bytes())
        if tree.root_node.has_error:
            raise RuntimeError(f"Swift syntax errors: {path}")
    print("PASS OpenStep plist and Swift grammar checks (not an Apple SDK typecheck)")
else:
    print("Swift grammar check skipped. Native compilation must be run in Xcode.")
