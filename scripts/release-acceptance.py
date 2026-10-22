#!/usr/bin/env python3
"""Validate published-release/source/tap alignment without installing anything."""
import argparse
import hashlib
import json
import re
import subprocess
from pathlib import Path

REPOSITORY = "VincentShipsIt/macsweep.dev"
TAP = "vincentshipsit/tap/macsweep"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(text):
    value = text.strip()
    require(re.fullmatch(r"[0-9a-f]{64}", value), "Invalid published SHA256")
    return value


def validate_notes(body, version):
    require(re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version), "Notes version must be X.Y.Z")
    for heading in ("GUI scope", "Deferred features"):
        require(re.search(rf"(?mi)^## {heading}\s*\n\s*\S", body), f"Release notes lack explicit {heading}")
    require(version in body, "Release notes do not name the version")
    require("iOS" in body and "macOS 26" in body, "Release notes omit supported/deferred platform scope")


def validate(data):
    release, cask, formula = data["release"], data["cask"]["casks"], data["formula"]["formulae"]
    tag = release["tag_name"]
    require(re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", tag), "Release tag must be vX.Y.Z")
    version = tag[1:]
    require(not release["draft"] and not release["prerelease"], "A stable published release is required")
    require(release.get("published_at"), "Release publication time is missing")
    require(release["html_url"] == f"https://github.com/{REPOSITORY}/releases/tag/{tag}", "Unexpected release URL")
    require(len(cask) == len(formula) == 1, "Expected exactly one cask and formula")
    cask, formula = cask[0], formula[0]
    app_url = f"https://github.com/{REPOSITORY}/releases/download/{tag}/macsweep-{tag}-macos.zip"
    source_url = f"https://github.com/{REPOSITORY}/archive/refs/tags/{tag}.tar.gz"
    require(cask["version"] == version and cask["url"] == app_url, "Cask version/URL drift")
    require(formula["versions"]["stable"] == version, "Formula version drift")
    legacy_source_url = f"https://github.com/VincentShipsIt/macsweep/archive/refs/tags/{tag}.tar.gz"
    formula_source = formula["urls"]["stable"]["url"]
    require(formula_source in (source_url, legacy_source_url), "Formula source tag drift")
    app_sha, source_sha = digest(data["app_sha"]), digest(data["source_sha"])
    require(cask["sha256"] == app_sha, "Cask checksum differs from published checksum")
    require(formula["urls"]["stable"]["checksum"] == source_sha, "Formula checksum differs from release")
    dependencies = cask.get("depends_on", {}).get("formula", [])
    require(TAP in dependencies, "Cask must install the CLI formula dependency")
    require(any(item.get("app") == ["MacSweep.app"] for item in cask["artifacts"]), "Cask app artifact missing")
    require(any("binary" in item for item in cask["artifacts"]), "Cask CLI binary artifact missing")
    swift_versions = re.findall(r'static let current = "([^"]+)"', data["swift"])
    require(swift_versions == [version], "Tagged CLI version drift")
    for key in ("MARKETING_VERSION", "CURRENT_PROJECT_VERSION"):
        values = re.findall(rf"\b{key}\s*=\s*([^;]+);", data["pbx"])
        require(values and set(values) == {version}, f"Tagged {key} drift")
    body = release.get("body", "")
    validate_notes(body, version)
    assets = release["assets"]
    for name in (f"macsweep-{tag}-macos.zip", f"macsweep-{tag}-macos.zip.sha256", f"macsweep-{tag}.tar.gz.sha256"):
        matches = [asset for asset in assets if asset["name"] == name]
        require(len(matches) == 1 and matches[0]["state"] == "uploaded", f"Missing/duplicate release asset: {name}")
        require(matches[0]["browser_download_url"] == f"https://github.com/{REPOSITORY}/releases/download/{tag}/{name}", "Unexpected asset URL")
    app_asset = next(asset for asset in assets if asset["name"] == f"macsweep-{tag}-macos.zip")
    require(app_asset.get("digest") == f"sha256:{app_sha}", "GitHub app asset digest mismatch")
    return {"tag": tag, "version": version, "appSHA256": app_sha, "sourceSHA256": source_sha,
            "releaseURL": release["html_url"], "releaseNotesSHA256": hashlib.sha256(body.encode()).hexdigest(),
            "publishedAt": release["published_at"], "sourceURL": formula_source,
            "historicalRepositoryAlias": formula_source == legacy_source_url, "metadataAligned": True}


def validate_installed(data):
    version = data["version"]
    require(data["app_version"].strip() == version, "Installed GUI version drift")
    require(data["app_build"].strip() == version, "Installed GUI build drift")
    require(data["app_id"].strip() == "dev.macsweep.app", "Installed GUI bundle identity drift")
    require(re.fullmatch(r"macsweep(?:\.dev)? " + re.escape(version) + r"\s*", data["cli_version"]),
            "Installed CLI version drift")
    casks, formulae = data["cask"]["casks"], data["formula"]["formulae"]
    require(len(casks) == len(formulae) == 1, "Expected one installed cask/formula")
    require(casks[0]["installed"] == version, "Installed cask version drift")
    require(any(row["version"] == version for row in formulae[0]["installed"]), "Installed formula version drift")
    return {"version": version, "appAndCLIAligned": True}


def installed(directory):
    data = {"version": json.loads((directory / "metadata.json").read_text())["version"]}
    for key, filename in (("app_version", "app-version.txt"), ("app_build", "app-build.txt"),
                          ("app_id", "app-id.txt"), ("cli_version", "cli-version.txt")):
        data[key] = (directory / filename).read_text()
    for key in ("cask", "formula"):
        data[key] = json.loads((directory / f"installed-{key}.json").read_text())
    return validate_installed(data)


def freshness(directory, run=subprocess.run):
    commands = (("casks", ["brew", "list", "--cask", "--versions"]),
                ("formulae", ["brew", "list", "--formula", "--versions"]),
                ("processes", ["pgrep", "-x", "MacSweep"]))
    results = {}
    for name, command in commands:
        result = run(command, capture_output=True, text=True, timeout=30, check=False)
        (directory / f"preexisting-{name}.txt").write_text(result.stdout)
        (directory / f"preexisting-{name}-stderr.txt").write_text(result.stderr)
        results[name] = {"exitStatus": result.returncode, "stdout": result.stdout, "stderr": result.stderr}
    (directory / "freshness-command-status.json").write_text(json.dumps(
        {name: {"exitStatus": row["exitStatus"]} for name, row in results.items()}, indent=2) + "\n")
    for name in ("casks", "formulae"):
        row = results[name]
        require(row["exitStatus"] == 0, f"Homebrew {name} inventory failed; freshness is unknown")
        for line in row["stdout"].splitlines():
            fields = line.split()
            if not fields:
                continue
            require(len(fields) >= 2 and re.fullmatch(r"[A-Za-z0-9@+_.-]+(?:/[A-Za-z0-9@+_.-]+)*", fields[0]),
                    f"Malformed Homebrew {name} inventory; freshness is unknown")
            require(fields[0] not in ("macsweep", TAP), f"MacSweep already installed in {name}")
    processes = results["processes"]
    require(processes["exitStatus"] != 0, "MacSweep already running")
    require(processes["exitStatus"] == 1 and not processes["stdout"].strip() and not processes["stderr"].strip(),
            "MacSweep process inspection failed; freshness is unknown")
    return {"packagesAbsent": True, "processAbsent": True, "nativeInventoriesSucceeded": True}


def load(directory):
    data = {key: json.loads((directory / f"{key}.json").read_text()) for key in ("release", "cask", "formula")}
    for key, filename in (("swift", "MacSweepVersion.swift"), ("pbx", "project.pbxproj"),
                          ("app_sha", "app.sha256"), ("source_sha", "source.sha256")):
        data[key] = (directory / filename).read_text()
    return data


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path, nargs="?")
    parser.add_argument("--freshness", type=Path)
    parser.add_argument("--installed", type=Path)
    parser.add_argument("--notes", type=Path)
    parser.add_argument("--version")
    args = parser.parse_args()
    try:
        if args.freshness:
            receipt = freshness(args.freshness)
            (args.freshness / "package-process-freshness.json").write_text(json.dumps(receipt, indent=2) + "\n")
            print(json.dumps(receipt))
            raise SystemExit(0)
        if args.installed:
            receipt = installed(args.installed)
            (args.installed / "installed-alignment.json").write_text(json.dumps(receipt, indent=2) + "\n")
            print(json.dumps(receipt))
            raise SystemExit(0)
        if args.notes:
            validate_notes(args.notes.read_text(), args.version or "")
            print("Release notes include the version, GUI scope and deferred features.")
            raise SystemExit(0)
        require(args.directory is not None, "A metadata directory or --notes file is required")
        receipt = validate(load(args.directory))
        (args.directory / "metadata.json").write_text(json.dumps(receipt, indent=2) + "\n")
        print(json.dumps(receipt))
    except (KeyError, TypeError, ValueError, OSError, subprocess.TimeoutExpired) as error:
        parser.exit(1, f"Release metadata acceptance failed: {error}\n")
