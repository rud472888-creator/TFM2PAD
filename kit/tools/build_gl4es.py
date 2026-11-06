#!/usr/bin/env python3
"""Build pinned upstream GL4ES for an existing iOS EAGL backend, without installation."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

UPSTREAM = "https://github.com/ptitSeb/gl4es.git"
COMMIT = "bc4314d8369f169d3fa81c5ed1b46b3dba4e74a5"


def run(argv, env, output, report, label):
    result = subprocess.run(argv, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    log = output / (label + ".log")
    log.write_text(result.stdout + result.stderr)
    report["commands"].append({"argv": argv, "exit_code": result.returncode, "log": log.name})
    if result.returncode:
        raise RuntimeError(f"{label} failed ({result.returncode}); see {log}")
    return result.stdout


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True, type=Path, help="Unmodified official checkout at the pinned commit")
    parser.add_argument("--output", required=True, type=Path, help="Fresh local build directory")
    args = parser.parse_args()
    source = args.source.resolve(strict=True)
    output = args.output.resolve()
    env = dict(os.environ)
    actual = subprocess.check_output(["git", "-C", str(source), "rev-parse", "HEAD"], text=True).strip()
    if actual != COMMIT:
        parser.error(f"Expected official GL4ES commit {COMMIT}, got {actual}")
    if subprocess.run(["git", "-C", str(source), "diff", "--quiet", "HEAD", "--"], env=env).returncode:
        parser.error("Upstream checkout has tracked modifications; this build requires unmodified source")
    if output.exists():
        parser.error("--output must be a fresh directory")
    output.mkdir(parents=True)
    (output / "INCOMPLETE").write_text("Build incomplete; do not integrate.\n")
    report = {"schema_version": 1, "status": "incomplete", "upstream": UPSTREAM, "commit": COMMIT,
              "upstream_version": "1.1.7", "license": "MIT", "license_sha256": sha(source / "LICENSE"),
              "generated_at": datetime.now(timezone.utc).isoformat(), "commands": [],
              "target": "arm64 iOS device, minimum iOS15", "desktop_api_target": "OpenGL2.1 / GLSL1.20 emulation over GLES2 backend",
              "build_adaptations": ["Build-local AliasDecl forwarding for exactly two void(array,index) aliases unsupported by Mach-O clang; upstream source files unchanged.", "Target-final default visibility permits dynamic integration exports; upstream otherwise forces hidden visibility on Apple."],
              "limitations": ["Not desktop OpenGL4.1; no higher version override is enabled.",
                              "Compilation is not device rendering or original Skia validation.",
                              "Upstream glDrawBuffer and glReadBuffer are logging stubs.",
                              "glBindFragDataLocation is absent in this pinned source.",
                              "Known upstream limits include crude shader conversion, multiple color attachments, depth/stencil readback, and texture features."],
              "integration": {"context": "Create and make current an actual EAGL context first; gl4es does not create it.",
                              "driver_callback": "set_getprocaddress or gl4es_set_getprocaddress; callback must dlsym the real OpenGLES framework handle, never this wrapper.",
                              "size_callback": "set_getmainfbsize supplies actual drawable width and height.",
                              "initialization": "Set callbacks, then initialize_gl4es once before wrapper GL calls.",
                              "resolver": "gl4es_GetProcAddress supplies wrapper entrypoints to original desktop Skia.",
                              "state": "Do not mix wrapper stateful GL calls with raw GLES calls without an explicit state contract; EAGL present remains host-owned."}}
    try:
        sdk = run(["xcrun", "--sdk", "iphoneos", "--show-sdk-path"], env, output, report, "sdk").strip()
        compiler = run(["xcrun", "--sdk", "iphoneos", "--find", "clang"], env, output, report, "compiler").strip()
        # Upstream forces output paths into its checkout. A deferred CMake target
        # property redirects artifacts without editing that upstream source.
        redirect = output / "redirect-output.cmake"
        darwin_compat = output / "darwin-alias-compat.h"
        alias_uses = [line.strip() for line in (source / "src/gl/directstate.c").read_text().splitlines() if line.startswith("AliasDecl(")]
        expected_aliases = ["AliasDecl(void,gl4es_glEnableClientStatei,(GLenum array, GLuint index),gl4es_glEnableClientStateIndexed);", "AliasDecl(void,gl4es_glDisableClientStatei,(GLenum array, GLuint index),gl4es_glDisableClientStateIndexed);"]
        if alias_uses != expected_aliases:
            raise RuntimeError("Pinned Darwin alias sites differ from reviewed two-argument forwarding cases")
        darwin_compat.write_text("// Build-local Mach-O equivalents for the two reviewed void(array,index) aliases.\n#define AliasDecl(RET,NAME,DEF,OLD) RET APIENTRY_GL4ES NAME DEF { OLD(array,index); }\n")
        redirect.write_text('function(tfm_gl4es_target_config)\n  set_target_properties(GL PROPERTIES ARCHIVE_OUTPUT_DIRECTORY "' + str(output / "lib") + '")\n  target_compile_options(GL PRIVATE -fvisibility=default -include "' + str(darwin_compat) + '")\nendfunction()\ncmake_language(DEFER CALL tfm_gl4es_target_config)\n')
        cmake = shutil.which("cmake")
        ninja = shutil.which("ninja")
        if not cmake or not ninja:
            raise RuntimeError("Existing cmake and ninja executables are required; nothing is installed by this script")
        configure = [cmake, "-S", str(source), "-B", str(output / "cmake"), "-G", "Ninja",
                     "-DCMAKE_SYSTEM_NAME=iOS", "-DCMAKE_OSX_ARCHITECTURES=arm64", "-DCMAKE_OSX_DEPLOYMENT_TARGET=15.0",
                     "-DCMAKE_OSX_SYSROOT=" + sdk, "-DCMAKE_C_COMPILER=" + compiler,
                     "-DCMAKE_BUILD_TYPE=Release", "-DCMAKE_POLICY_VERSION_MINIMUM=3.5", "-DCMAKE_MAKE_PROGRAM=" + ninja,
                     "-DCMAKE_PROJECT_INCLUDE=" + str(redirect), "-DCMAKE_EXPORT_COMPILE_COMMANDS=ON",
                     "-DNOX11=ON", "-DNOEGL=ON", "-DSTATICLIB=ON", "-DNO_LOADER=ON", "-DNO_INIT_CONSTRUCTOR=ON",
                     "-DDEFAULT_ES=2", "-DGBM=OFF", "-DUSE_CCACHE=OFF", "-DCMAKE_C_FLAGS=-fvisibility=default"]
        run(configure, env, output, report, "configure")
        run([cmake, "--build", str(output / "cmake"), "--target", "GL", "--parallel", "4"], env, output, report, "compile")
        archive = output / "lib/libGL.a"
        if not archive.is_file():
            raise RuntimeError("CMake did not emit the expected redirected static archive")
        # These aliases expose the explicit callback names requested by the host;
        # upstream's real implementations remain unchanged.
        bridge = output / "callback-aliases.c"
        bridge.write_text('#include "gl4esinit.h"\n__attribute__((visibility("default"))) void gl4es_set_getprocaddress(void *(*callback)(const char *)) { set_getprocaddress(callback); }\n__attribute__((visibility("default"))) void gl4es_set_getmainfbsize(void (*callback)(int *, int *)) { set_getmainfbsize(callback); }\n')
        dylib = output / "TFMGL4ES.dylib"
        run(["xcrun", "--sdk", "iphoneos", "clang", "-arch", "arm64", "-isysroot", sdk, "-miphoneos-version-min=15.0",
             "-dynamiclib", "-I", str(source / "include"), str(bridge), "-Wl,-force_load," + str(archive),
             "-Wl,-install_name,@rpath/TFMGL4ES.dylib", "-framework", "OpenGLES", "-o", str(dylib)], env, output, report, "link-dylib")
        exports_text = run(["xcrun", "nm", "-arch", "arm64", "-gU", str(dylib)], env, output, report, "exports")
        exports = {line.split()[-1] for line in exports_text.splitlines() if line.split() and not line.rstrip().endswith(":")}
        required = {"_gl4es_GetProcAddress", "_initialize_gl4es", "_close_gl4es", "_set_getprocaddress", "_set_getmainfbsize", "_gl4es_set_getprocaddress", "_gl4es_set_getmainfbsize"}
        missing = required - exports
        if missing:
            raise RuntimeError("Required integration APIs are not dynamically exported: " + ", ".join(sorted(missing)))
        report["required_exports_verified"] = sorted(required)
        report["wrapper_export_count"] = sum(name.startswith("_gl4es_gl") for name in exports)
        report["artifacts"] = [{"file": str(path.relative_to(output)), "sha256": sha(path), "size": path.stat().st_size} for path in (archive, dylib)]
        report["macho_dependencies"] = run(["xcrun", "otool", "-arch", "arm64", "-L", str(dylib)], env, output, report, "dependencies")
        report["status"] = "compiled_not_device_validated"
        (output / "LICENSE.gl4es").write_bytes((source / "LICENSE").read_bytes())
        (output / "gl4esinit.h").write_bytes((source / "include/gl4esinit.h").read_bytes())
        (output / "INCOMPLETE").unlink()
    except Exception as error:
        report["error"] = str(error)
        (output / "build-report.json").write_text(json.dumps(report, indent=2) + "\n")
        parser.exit(1, str(error) + "\n")
    (output / "build-report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({"output": str(output), "status": report["status"], "wrapper_exports": report["wrapper_export_count"], "commit": COMMIT}, indent=2))


if __name__ == "__main__":
    main()
