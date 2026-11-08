"""Validate the source and optional per-release Plus identity."""
import json
import os
from pathlib import Path
import re


def require(condition, message):
    if not condition:
        raise ValueError(message)


def normalize_metadata(m):
    require(isinstance(m, dict), "Release metadata must be an object")
    allowed = {"schema", "product", "upstream_version", "upstream_commit", "revision", "build", "source_commit", "tag", "asset"}
    required = {"schema", "product", "upstream_version", "upstream_commit", "revision", "build"}
    require(required <= m.keys() and m.keys() <= allowed, "Invalid release metadata fields")
    require(type(m["schema"]) is int and m["schema"] == 1 and m["product"] == "VoiceInk Plus", "Unsupported release metadata")
    require(isinstance(m["upstream_version"], str) and re.fullmatch(r"[0-9]+(?:\.[0-9]+){1,2}", m["upstream_version"]) is not None, "Invalid upstream version")
    require(isinstance(m["upstream_commit"], str) and re.fullmatch(r"[a-f0-9]{40}", m["upstream_commit"]) is not None, "Invalid upstream commit")
    require(type(m["revision"]) is int and 0 < m["revision"] < 10**9, "Invalid revision")
    require(type(m["build"]) is int and 225 < m["build"] < 2147483647, "Invalid build")
    if "source_commit" in m:
        require(isinstance(m["source_commit"], str) and re.fullmatch(r"[a-f0-9]{40}", m["source_commit"]) is not None, "Invalid source commit")
    tag = f"plus-v{m['upstream_version']}-r{m['revision']}"
    asset = f"VoiceInk-Plus-{m['upstream_version']}-r{m['revision']}-AppleSilicon.zip"
    require("tag" not in m or m["tag"] == tag, "Release tag mismatch")
    require("asset" not in m or m["asset"] == asset, "Release asset mismatch")
    return {**m, "tag": tag, "asset": asset}


def base_metadata(root: Path):
    return normalize_metadata(json.loads((root / "release/plus.json").read_text()))


def _unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, f"Duplicate release metadata field: {key}")
        result[key] = value
    return result


def effective_metadata(root: Path, source: str):
    base = base_metadata(root)
    raw = os.environ.get("VOICEINK_RELEASE_METADATA")
    if raw is None:
        return base
    require(len(raw.encode("utf-8")) <= 16 * 1024, "Release metadata exceeds 16 KiB")
    override = json.loads(raw, object_pairs_hook=_unique_object)
    require(isinstance(override, dict) and {"source_commit", "tag", "asset"} <= override.keys(), "Override requires source_commit, tag and asset")
    m = normalize_metadata(override)
    require(isinstance(source, str) and re.fullmatch(r"[a-f0-9]{40}", source) is not None and m["source_commit"] == source, "Release source commit mismatch")
    require(all(m[k] == base[k] for k in ("product", "upstream_version", "upstream_commit")), "Release upstream identity mismatch")
    require(m["build"] >= base["build"], "Release build is below source baseline")
    return m


def info_fields(m):
    return {"CFBundleShortVersionString": m["upstream_version"], "CFBundleVersion": str(m["build"]),
            "VoiceInkPlusProduct": m["product"], "VoiceInkPlusRevision": str(m["revision"]),
            "VoiceInkPlusTag": m["tag"], "VoiceInkUpstreamCommit": m["upstream_commit"]}
