#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Package a native module and its runtime dependencies for GitHub Releases.

Linux packaging runs on Debian/Ubuntu with matching deb-src repositories.
It keeps shared libraries replaceable and ships their notices and sources.
"""

import argparse
import hashlib
import json
import platform
import re
import shutil
import subprocess
import tarfile
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
# These are supplied by the target's glibc, never copied from the build host.
GLIBC = re.compile(r"^(ld-linux.*|lib(c|m|dl|pthread|rt|resolv|util)\.so\..*)$")


def run(*args, cwd=None):
    return subprocess.check_output(args, cwd=cwd, text=True).strip()


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def dependencies(module):
    output = run("ldd", str(module))
    if "not found" in output:
        raise RuntimeError(f"Unresolved module dependencies:\n{output}")
    return {match[1]: Path(match[2]) for match in re.finditer(
        r"^\s*(\S+) => (/\S+) \(", output, re.MULTILINE) if not GLIBC.fullmatch(match[1])}


def package_owner(path):
    # dpkg may record pre-usrmerge paths; ldd may return either spelling.
    candidates = [str(path), str(path.resolve())]
    candidates += [p.removeprefix("/usr") for p in candidates if p.startswith("/usr/lib/")]
    candidates += ["/usr" + p for p in candidates[:] if p.startswith("/lib/")]
    for candidate in dict.fromkeys(candidates):
        found = subprocess.run(["dpkg-query", "-S", candidate], text=True, capture_output=True)
        if found.returncode == 0:
            return found.stdout.split(": ", 1)[0]
    raise RuntimeError(f"No Debian package owns {path}; cannot collect its license and source")


def linux_bundle(module, staging, sources):
    libraries = dependencies(module)
    if not any(name.startswith("libpango") for name in libraries):
        raise RuntimeError("Release modules must include real font measurements; rebuild with TEXT_BACKEND=pango")
    libdir = staging / "lib"
    libdir.mkdir()
    packages = {}
    for name, original in sorted(libraries.items()):
        target = libdir / name
        shutil.copy2(original, target)
        run("patchelf", "--set-rpath", "$ORIGIN", str(target))
        run("strip", "--strip-unneeded", str(target))
        package = package_owner(original)
        if package not in packages:
            binary_version, source, version = run(
                "dpkg-query", "-W", "-f=${Version}\t${source:Package}\t${source:Version}", package).split("\t")
            notice = Path("/usr/share/doc") / package.split(":")[0] / "copyright"
            destination = staging / "licenses" / package.replace(":", "-")
            destination.mkdir()
            shutil.copy2(notice, destination / "copyright")
            packages[package] = {"version": binary_version, "source": source, "sourceVersion": version}
    run("patchelf", "--set-rpath", "$ORIGIN/lib", str(module))
    run("strip", "--strip-unneeded", str(module))
    # Check every transitive dependency, not just the module's direct links.
    for name, resolved in dependencies(module).items():
        if resolved.resolve().parent != libdir.resolve():
            raise RuntimeError(f"Dependency escaped the bundle: {name} => {resolved}")
    shutil.copytree("/usr/share/common-licenses", staging / "licenses" / "common-licenses")
    for source, version in sorted({(p["source"], p["sourceVersion"]) for p in packages.values()}):
        subprocess.run(["apt-get", "source", "--download-only", "--only-source", f"{source}={version}"],
                       cwd=sources, check=True)
    (sources / "packages.json").write_text(json.dumps(packages, indent=2) + "\n")
    return packages


def macos_check(module):
    install_name = run("otool", "-D", str(module)).splitlines()[1]
    linked = [line.strip().split(" (", 1)[0] for line in run("otool", "-L", str(module)).splitlines()[1:]]
    linked = [name for name in linked if name != install_name]
    if not any("/CoreText.framework/" in name for name in linked):
        raise RuntimeError("Release modules must use the system Core Text backend")
    if any(not name.startswith(("/usr/lib/", "/System/Library/")) for name in linked):
        raise RuntimeError(f"Module links to non-system libraries: {linked}")
    run("strip", "-x", str(module))
    run("codesign", "--force", "--sign", "-", str(module))


def archive(directory, destination):
    with tarfile.open(destination, "w:gz") as output:
        for path in sorted(directory.iterdir()):
            output.add(path, arcname=path.name)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("module", type=Path)
    parser.add_argument("--output", type=Path, default=ROOT / "dist")
    args = parser.parse_args()
    system = platform.system().lower()
    if system not in ("darwin", "linux"):
        parser.error("Only macOS and glibc Linux are supported")
    arch = {"arm64": "aarch64", "amd64": "x86_64"}.get(platform.machine().lower(), platform.machine().lower())
    if arch not in ("aarch64", "x86_64"):
        parser.error(f"Unsupported architecture: {arch}")
    version = re.search(r'\(defconst pele-version "([^"]+)"', (ROOT / "pele.el").read_text())[1]
    stem = f"pele-native-{version}-{'macos' if system == 'darwin' else system}-{arch}"
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="pele-package-") as temporary:
        staging = Path(temporary) / "module"
        sources = Path(temporary) / "sources"
        staging.mkdir()
        sources.mkdir()
        module = staging / args.module.name
        shutil.copy2(args.module, module)
        (staging / "licenses").mkdir()
        for name, original in (("pele.el", ROOT / "LICENSE"), ("pele", ROOT / "vendor/pele/LICENSE"),
                               ("quickjs", ROOT / "vendor/quickjs/LICENSE")):
            shutil.copy2(original, staging / "licenses" / f"{name}.txt")
        metadata = {"version": version, "moduleABI": 1, "platform": system, "architecture": arch,
                    "minimumSystem": {"macos": "12.0"} if system == "darwin" else {"glibc": "2.35"},
                    "textBackend": "coretext" if system == "darwin" else "pango"}
        if system == "linux":
            metadata["packages"] = linux_bundle(module, staging, sources)
            source_archive = output / f"{stem}-sources.tar.gz"
            archive(sources, source_archive)
            metadata["dependencySources"] = source_archive.name
        else:
            macos_check(module)
        metadata["files"] = {str(p.relative_to(staging)): digest(p) for p in sorted(staging.rglob("*")) if p.is_file()}
        (staging / "manifest.json").write_text(json.dumps(metadata, indent=2) + "\n")
        (staging / "README.txt").write_text(
            "Extract this archive alongside pele.el. Keep lib/, licenses/ and manifest.json together with the module.\n"
            "Fonts are read from your computer; no fonts are bundled. Restart Emacs after replacing a loaded module.\n"
            "See licenses/ for third-party notices. Linux dependency sources are provided in the companion sources archive.\n")
        destination = output / f"{stem}.tar.gz"
        archive(staging, destination)
        for artifact in sorted(output.glob(f"{stem}*.tar.gz")):
            artifact.with_name(artifact.name + ".sha256").write_text(f"{digest(artifact)}  {artifact.name}\n")
            print(artifact)


if __name__ == "__main__":
    main()
