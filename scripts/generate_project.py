"""Generate the Xcode project without requiring XcodeGen on the host."""
import hashlib
import json
import plistlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / "verness.xcodeproj"


def ident(value):
    return hashlib.sha1(value.encode()).hexdigest()[:24].upper()


def quote(value):
    return json.dumps(str(value), ensure_ascii=False)


objects = {}


def obj(key, value):
    uid = ident(key)
    objects[uid] = value
    return uid


def array(items):
    return "(" + ", ".join(items) + ")"


def config(key, settings):
    return obj(key, "{ isa = XCBuildConfiguration; buildSettings = { " + " ".join(f"{name} = {quote(value)};" for name, value in settings.items()) + " }; name = " + quote(key.split(":")[-1]) + "; }")


def config_list(key, settings):
    ids = []
    for mode in ("Debug", "Release"):
        values = {**settings, "SWIFT_OPTIMIZATION_LEVEL": "-Onone" if mode == "Debug" else "-O", "DEBUG_INFORMATION_FORMAT": "dwarf" if mode == "Debug" else "dwarf-with-dsym"}
        if mode == "Debug":
            values["ENABLE_TESTABILITY"] = "YES"
        ids.append(config(key + ":" + mode, values))
    return obj(key + ":configs", "{ isa = XCConfigurationList; buildConfigurations = " + array(ids) + "; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; }")


def file_ref(path, kind):
    return obj("file:" + path, f"{{ isa = PBXFileReference; lastKnownFileType = {quote(kind)}; path = {quote(path)}; sourceTree = SOURCE_ROOT; }}")


app_sources = sorted(p.relative_to(ROOT).as_posix() for p in (ROOT / "App").glob("*.swift"))
shared_sources = sorted(p.relative_to(ROOT).as_posix() for p in (ROOT / "Shared").glob("*.swift"))
widget_sources = ["Island/IslandWidget.swift"]
tests = sorted(p.relative_to(ROOT).as_posix() for p in (ROOT / "Tests").glob("*.swift"))
all_files = {path: file_ref(path, "sourcecode.swift") for path in app_sources + shared_sources + widget_sources + tests}
for asset in ("App/Assets.xcassets", "Island/Assets.xcassets"):
    all_files[asset] = file_ref(asset, "folder.assetcatalog")
for info in ("App/Info.plist", "Island/Info.plist"):
    all_files[info] = file_ref(info, "text.plist.xml")
all_files["Shared/Localizable.xcstrings"] = file_ref("Shared/Localizable.xcstrings", "text.json.xcstrings")

product_ids = {}
for name, suffix, kind in (("verness", ".app", "wrapper.application"), ("VernessIsland", ".appex", "wrapper.app-extension"), ("VernessTests", ".xctest", "wrapper.cfbundle")):
    product_ids[name] = obj("product:" + name, f"{{ isa = PBXFileReference; explicitFileType = {quote(kind)}; includeInIndex = 0; path = {quote(name + suffix)}; sourceTree = BUILT_PRODUCTS_DIR; }}")

products = obj("products", "{ isa = PBXGroup; children = " + array(product_ids.values()) + "; name = Products; sourceTree = \"<group>\"; }")
main_group = obj("main", "{ isa = PBXGroup; children = " + array(list(all_files.values()) + [products]) + "; sourceTree = \"<group>\"; }")


def phase(name, paths, isa):
    builds = [obj(name + ":" + path, "{ isa = PBXBuildFile; fileRef = " + all_files[path] + "; }") for path in paths]
    return obj(name, "{ isa = " + isa + "; buildActionMask = 2147483647; files = " + array(builds) + "; runOnlyForDeploymentPostprocessing = 0; }")


project_id = ident("project")
target_ids = {name: ident("target:" + name) for name in product_ids}


def dependency(name):
    proxy = obj("proxy:" + name, f"{{ isa = PBXContainerItemProxy; containerPortal = {project_id}; proxyType = 1; remoteGlobalIDString = {target_ids[name]}; remoteInfo = {name}; }}")
    return obj("dependency:" + name, f"{{ isa = PBXTargetDependency; target = {target_ids[name]}; targetProxy = {proxy}; }}")


base = {"SDKROOT": "iphoneos", "IPHONEOS_DEPLOYMENT_TARGET": "17.0", "SWIFT_VERSION": "5.0", "TARGETED_DEVICE_FAMILY": "1,2",
        "CODE_SIGN_STYLE": "Automatic", "CURRENT_PROJECT_VERSION": "1", "MARKETING_VERSION": "0.1.2", "CLANG_ENABLE_MODULES": "YES",
        "SWIFT_STRICT_CONCURRENCY": "targeted", "ENABLE_USER_SCRIPT_SANDBOXING": "YES"}
for name, source, assets, plist, bundle, product_type in (
    ("verness", app_sources + shared_sources, ["App/Assets.xcassets"], "App/Info.plist", "app.verness.ios", "com.apple.product-type.application"),
    ("VernessIsland", widget_sources + shared_sources, ["Island/Assets.xcassets"], "Island/Info.plist", "app.verness.ios.island", "com.apple.product-type.app-extension"),
    ("VernessTests", tests, [], "", "app.verness.ios.tests", "com.apple.product-type.bundle.unit-test"),
):
    settings = {**base, "PRODUCT_NAME": name, "PRODUCT_BUNDLE_IDENTIFIER": bundle, "PRODUCT_MODULE_NAME": "Verness" if name == "verness" else name,
                "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/Frameworks @executable_path/../../Frameworks"}
    settings["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] = "$(inherited) " + ("APP_TARGET" if name == "verness" else "WIDGET_TARGET" if name == "VernessIsland" else "")
    if plist:
        settings["INFOPLIST_FILE"] = plist
    else:
        settings.update({"GENERATE_INFOPLIST_FILE": "YES", "TEST_HOST": "$(BUILT_PRODUCTS_DIR)/verness.app/verness", "BUNDLE_LOADER": "$(TEST_HOST)"})
    if name == "verness":
        settings["ASSETCATALOG_COMPILER_APPICON_NAME"] = "AppIcon"
    if name == "VernessIsland":
        settings.update({"APPLICATION_EXTENSION_API_ONLY": "YES", "SKIP_INSTALL": "YES"})
    if name != "VernessTests":
        assets = assets + ["Shared/Localizable.xcstrings"]
    phases = [phase(name + ":sources", source, "PBXSourcesBuildPhase"), phase(name + ":resources", assets, "PBXResourcesBuildPhase"), phase(name + ":frameworks", [], "PBXFrameworksBuildPhase")]
    deps = []
    if name == "verness":
        embed = obj("embed:widget", "{ isa = PBXBuildFile; fileRef = " + product_ids["VernessIsland"] + "; settings = { ATTRIBUTES = (RemoveHeadersOnCopy,); }; }")
        phases.append(obj("embed", "{ isa = PBXCopyFilesBuildPhase; buildActionMask = 2147483647; dstPath = \"\"; dstSubfolderSpec = 13; files = (" + embed + ",); name = \"Embed App Extensions\"; runOnlyForDeploymentPostprocessing = 0; }"))
        deps = [dependency("VernessIsland")]
    if name == "VernessTests":
        deps = [dependency("verness")]
    configs = config_list(name, settings)
    obj("target:" + name, f"{{ isa = PBXNativeTarget; buildConfigurationList = {configs}; buildPhases = {array(phases)}; buildRules = (); dependencies = {array(deps)}; name = {quote(name)}; productName = {quote(name)}; productReference = {product_ids[name]}; productType = {quote(product_type)}; }}")

project_configs = config_list("project", {"CLANG_ENABLE_MODULES": "YES", "SWIFT_VERSION": "5.0", "IPHONEOS_DEPLOYMENT_TARGET": "17.0"})
obj("project", "{ isa = PBXProject; attributes = { BuildIndependentTargetsInParallel = YES; LastUpgradeCheck = 1600; }; buildConfigurationList = " + project_configs + "; compatibilityVersion = \"Xcode 14.0\"; developmentRegion = en; knownRegions = (ru, en, Base); mainGroup = " + main_group + "; productRefGroup = " + products + "; projectDirPath = \"\"; projectRoot = \"\"; targets = " + array(target_ids.values()) + "; }")

PROJECT.mkdir(exist_ok=True)
pbx = "// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n"
pbx += "\n".join(f"\t{key} = {value};" for key, value in objects.items())
pbx += f"\n}}; rootObject = {project_id}; }}\n"
(PROJECT / "project.pbxproj").write_text(pbx, encoding="utf-8")
scheme_dir = PROJECT / "xcshareddata/xcschemes"
scheme_dir.mkdir(parents=True, exist_ok=True)
def reference(name):
    suffix = ".app" if name == "verness" else ".xctest"
    return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target_ids[name]}" BuildableName="{name}{suffix}" BlueprintName="{name}" ReferencedContainer="container:verness.xcodeproj"/>'
scheme = f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{reference("verness")}</BuildActionEntry></BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO">{reference("VernessTests")}</TestableReference></Testables></TestAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference("verness")}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference("verness")}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>'''
(scheme_dir / "verness.xcscheme").write_text(scheme, encoding="utf-8")

info = {"CFBundleDisplayName": "verness", "CFBundleName": "$(PRODUCT_NAME)", "CFBundleIdentifier": "$(PRODUCT_BUNDLE_IDENTIFIER)",
        "CFBundleExecutable": "$(EXECUTABLE_NAME)", "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "$(MARKETING_VERSION)",
        "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)", "LSRequiresIPhoneOS": True, "UIBackgroundModes": ["audio"],
        "NSSupportsLiveActivities": True, "NSLocalNetworkUsageDescription": "verness connects to your own music server on the local network.",
        "NSAppTransportSecurity": {"NSAllowsLocalNetworking": True}, "UILaunchScreen": {},
        "UISupportedInterfaceOrientations": ["UIInterfaceOrientationPortrait", "UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight"],
        "UISupportedInterfaceOrientations~ipad": ["UIInterfaceOrientationPortrait", "UIInterfaceOrientationPortraitUpsideDown", "UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight"],
        "CFBundleURLTypes": [{"CFBundleURLName": "verness", "CFBundleURLSchemes": ["verness"]}],
        "CFBundleDocumentTypes": [{"CFBundleTypeName": "Audio", "LSHandlerRank": "Alternate", "LSItemContentTypes": ["public.audio"]}],
        "LSSupportsOpeningDocumentsInPlace": True}
(ROOT / "App/Info.plist").write_bytes(plistlib.dumps(info))
widget_info = {key: info[key] for key in ("CFBundleName", "CFBundleIdentifier", "CFBundleExecutable", "CFBundleShortVersionString", "CFBundleVersion")}
widget_info.update({"CFBundleDisplayName": "verness Island", "CFBundlePackageType": "XPC!", "NSExtension": {"NSExtensionPointIdentifier": "com.apple.widgetkit-extension"}})
(ROOT / "Island/Info.plist").write_bytes(plistlib.dumps(widget_info))
for folder in ("App", "Island"):
    assets = ROOT / folder / "Assets.xcassets"
    (assets / "Contents.json").write_text(json.dumps({"info": {"author": "xcode", "version": 1}}), encoding="utf-8")
    (assets / "Clover.imageset/Contents.json").write_text(json.dumps({"images": [{"filename": "clover.png", "idiom": "universal", "scale": "2x"}], "info": {"author": "xcode", "version": 1}}), encoding="utf-8")
(ROOT / "App/Assets.xcassets/AppIcon.appiconset/Contents.json").write_text(json.dumps({"images": [{"filename": "AppIcon.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"}], "info": {"author": "xcode", "version": 1}}), encoding="utf-8")
print("Generated verness.xcodeproj with app, Island extension, tests and shared scheme")
