#!/usr/bin/env python3
"""Maintain Plus identity and package a signed app; never publish or install."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile
from release_identity import base_metadata, effective_metadata, info_fields, require

ROOT = Path(__file__).resolve().parent.parent

def metadata():
    return base_metadata(ROOT)

def project_identity(m, write=False):
    path = ROOT / "VoiceInk.xcodeproj/project.pbxproj"
    text = path.read_text()
    matched = 0
    def main_settings(match):
        nonlocal matched
        body = match.group(2)
        if "INFOPLIST_FILE = VoiceInk/Info.plist;" not in body:
            return match.group(0)
        matched += 1
        for key, value in [("CURRENT_PROJECT_VERSION", str(m["build"])), ("MARKETING_VERSION", m["upstream_version"])]:
            found = re.search(rf"{key} = ([^;]+);", body)
            require(found, f"Missing main-app setting {key}")
            if write:
                body = re.sub(rf"{key} = [^;]+;", f"{key} = {value};", body)
            else:
                require(found.group(1) == value, f"Main-app {key} must be {value}; run sync-info")
        return match.group(1) + body + match.group(3)
    updated = re.sub(r"(?ms)(^\t\t\tbuildSettings = \{)(.*?)(^\t\t\t\};)", main_settings, text)
    require(matched == 2, "Expected only the main app Debug/Release settings")
    if write:
        path.write_text(updated)

def check_info(path, m):
    info = plistlib.loads(path.read_bytes())
    for key, expected in info_fields(m).items():
        require(info.get(key) == expected, f"{path}: {key} must be {expected!r}, found {info.get(key)!r}")
    require("SUFeedURL" not in info, "Upstream Sparkle feed must remain absent")
    return info

def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("operation", choices=["show", "sync-info", "check", "package", "pin-installer", "pin-bootstrap"])
    p.add_argument("--app", type=Path)
    p.add_argument("--output", type=Path)
    p.add_argument("--archive", type=Path)
    p.add_argument("--commit")
    a = p.parse_args()
    base = metadata()
    has_override = "VOICEINK_RELEASE_METADATA" in os.environ
    require(not (has_override and a.operation in ("sync-info", "pin-installer", "pin-bootstrap")), "Release metadata override is not allowed for source operations")
    source = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip() if has_override else ""
    m = effective_metadata(ROOT, source) if has_override else base
    source_info = ROOT / "VoiceInk/Info.plist"
    if a.operation == "show":
        print(json.dumps(m, indent=2)); return
    if a.operation == "sync-info":
        info = plistlib.loads(source_info.read_bytes()); info.update(info_fields(m))
        source_info.write_bytes(plistlib.dumps(info, sort_keys=False))
        project_identity(m, write=True)
        return
    project_identity(base)
    check_info(source_info, base)
    def check_app():
        info = check_info(a.app / "Contents/Info.plist", m)
        require(info.get("CFBundleIdentifier") == "com.prakashjoshipax.VoiceInk", "Unexpected app bundle identifier")
        if has_override:
            require(info.get("VoiceInkSourceCommit") == source, "App source commit mismatch")
        for helper in (a.app / "Contents").rglob("*.xpc/Contents/Info.plist"):
            h = plistlib.loads(helper.read_bytes())
            require("VoiceInkPlusTag" not in h and h.get("CFBundleVersion") != str(m["build"]), "Helper identity was globally overridden")
        return info
    if a.operation == "check":
        if a.app:
            check_app()
        print(f"Verified {m['product']} {m['tag']} (build {m['build']})"); return
    if a.operation == "package":
        assert a.app and a.output and a.app.is_dir(), "Pass --app and --output directory"
        app_info = check_app()
        assert "VoiceInkDevDescription" not in app_info, "Refusing to package a development app"
        subprocess.run(["codesign", "--verify", "--deep", "--strict", str(a.app)], check=True)
        a.output.mkdir(parents=True, exist_ok=True)
        archive = a.output / m["asset"]
        assert not archive.exists(), "Refusing to replace an existing archive"
        with tempfile.TemporaryDirectory(prefix="voiceink-plus-package-", dir="/private/tmp") as tmp:
            folder = Path(tmp) / "VoiceInk-Plus"; folder.mkdir()
            subprocess.run(["ditto", str(a.app), str(folder / "VoiceInk.app")], check=True)
            shutil.copy2(ROOT / "LICENSE", folder / "LICENSE")
            (folder / "SOURCE.txt").write_text(f"Source and build instructions: https://github.com/legrch/VoiceInk/tree/{m['tag']}\nUpstream: {m['upstream_commit']}\n")
            subprocess.run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(folder), str(archive.resolve())], check=True)
        checksum = hashlib.sha256(archive.read_bytes()).hexdigest()
        manifest = {key: m[key] for key in ("schema", "upstream_version", "revision", "build", "tag", "asset")}
        manifest["archive_sha256"] = checksum
        if "VoiceInkSourceCommit" in app_info:
            assert re.fullmatch(r"[a-f0-9]{40}", app_info["VoiceInkSourceCommit"]), "Invalid app source identity"
            manifest["source_commit"] = app_info["VoiceInkSourceCommit"]
        (a.output / "release.json").write_text(json.dumps(manifest, indent=2) + "\n")
        print(f"{checksum}  {archive.name}"); return
    if a.operation == "pin-installer":
        assert a.archive and a.archive.name == m["asset"], "Expected current release archive"
        digest = hashlib.sha256(a.archive.read_bytes()).hexdigest()
        path = ROOT / "scripts/install.sh"; text = path.read_text()
        previous = re.search(r"^VERSION=(.+)$", text, re.M).group(1)
        text = text.replace(previous, m["tag"])
        for key, value in [("VERSION", m["tag"]), ("ASSET", m["asset"]), ("ARCHIVE_SHA256", digest), ("UPSTREAM_VERSION", m["upstream_version"]), ("BUILD_NUMBER", str(m["build"]))]:
            text, count = re.subn(rf"^{key}=.*$", f"{key}={value}", text, count=1, flags=re.M)
            assert count == 1, f"Missing installer field {key}"
        path.write_text(text); print(digest); return
    assert a.commit and re.fullmatch(r"[a-f0-9]{40}", a.commit), "Pass exact installer --commit"
    payload = subprocess.check_output(["git", "show", f"{a.commit}:scripts/install.sh"], cwd=ROOT)
    assert payload == (ROOT / "scripts/install.sh").read_bytes(), "Committed installer differs from current source"
    path = ROOT / "scripts/install-release.sh"; text = path.read_text()
    text = re.sub(r"plus-v[0-9]+(?:\.[0-9]+){1,2}-r[0-9]+", m["tag"], text)
    text, count = re.subn(r"^    plus_installer_url=.*$", f"    plus_installer_url=https://raw.githubusercontent.com/legrch/VoiceInk/{a.commit}/scripts/install.sh", text, count=1, flags=re.M)
    assert count == 1
    text, count = re.subn(r"^    plus_installer_sha256=.*$", f"    plus_installer_sha256={hashlib.sha256(payload).hexdigest()}", text, count=1, flags=re.M)
    assert count == 1
    path.write_text(text)

if __name__ == "__main__":
    main()
