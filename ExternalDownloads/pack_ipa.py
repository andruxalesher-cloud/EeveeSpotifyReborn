"""Add the compiled library to the supplied decrypted Spotify 9.1.0 IPA.

The resulting IPA must be signed with the user's own provisioning profile.
Only arm64 Mach-O files with sufficient existing header padding are supported.
"""
import argparse
import os
from pathlib import Path
import plistlib
import struct
import tempfile
import zipfile


LIBRARY_PATH = b"@executable_path/Frameworks/ExternalDownloads.dylib\0"


def inject(binary):
    data = bytearray(binary)
    if len(data) < 32:
        raise ValueError("Truncated executable")
    magic, cpu, _, kind, count, command_bytes = struct.unpack_from("<6I", data)
    if (magic, cpu, kind) != (0xFEEDFACF, 0x100000C, 2):
        raise ValueError("Expected a thin arm64 executable")
    end = 32 + command_bytes
    if end > len(data):
        raise ValueError("Invalid load command bounds")
    offset = 32
    first_section = len(data)
    for _ in range(count):
        command, size = struct.unpack_from("<II", data, offset)
        if size < 8 or offset + size > end:
            raise ValueError("Invalid load command")
        if command == 0x2C and struct.unpack_from("<I", data, offset + 16)[0]:
            raise ValueError("Executable is encrypted")
        if command in (0xC, 0x80000018):
            name_offset = struct.unpack_from("<I", data, offset + 8)[0]
            name = bytes(data[offset + name_offset:offset + size]).split(b"\0")[0]
            if name.endswith(b"/ExternalDownloads.dylib"):
                raise ValueError("The input already contains this add-on")
        if command == 0x19:
            sections = struct.unpack_from("<I", data, offset + 64)[0]
            if 72 + sections * 80 > size:
                raise ValueError("Invalid segment section table")
            for index in range(sections):
                section = offset + 72 + index * 80
                file_offset = struct.unpack_from("<I", data, section + 48)[0]
                if file_offset:
                    first_section = min(first_section, file_offset)
        offset += size
    if offset != end:
        raise ValueError("Load command count disagrees with header")
    size = (24 + len(LIBRARY_PATH) + 7) & ~7
    if end + size > first_section or any(data[end:end + size]):
        raise ValueError("Insufficient empty header padding for safe insertion")
    command = struct.pack("<6I", 0xC, size, 24, 0, 0x10000, 0x10000) + LIBRARY_PATH
    data[end:end + size] = command.ljust(size, b"\0")
    struct.pack_into("<II", data, 16, count + 1, command_bytes + size)
    return bytes(data)


def pack(ipa, library, output):
    ipa, library, output = Path(ipa), Path(library), Path(output)
    if ipa.resolve() == output.resolve() or output.exists():
        raise ValueError("Choose a new output path")
    lib = library.read_bytes()
    if len(lib) < 32 or struct.unpack_from("<II", lib) != (0xFEEDFACF, 0x100000C):
        raise ValueError("Expected a compiled arm64 dylib")
    if struct.unpack_from("<I", lib, 12)[0] != 6:
        raise ValueError("Input library is not a Mach-O dylib")
    output.parent.mkdir(parents=True, exist_ok=True)
    handle, temporary = tempfile.mkstemp(dir=output.parent, suffix=".ipa.tmp")
    os.close(handle)
    try:
        with zipfile.ZipFile(ipa) as source:
            names = source.namelist()
            if len(names) != len(set(names)):
                raise ValueError("Input archive contains duplicate entries")
            root = "Payload/Spotify.app/"
            info = plistlib.loads(source.read(root + "Info.plist"))
            if info.get("CFBundleShortVersionString") != "9.1.0":
                raise ValueError("This add-on targets Spotify 9.1.0")
            executable = root + info["CFBundleExecutable"]
            updated = inject(source.read(executable))
            with zipfile.ZipFile(temporary, "w") as target:
                for entry in source.infolist():
                    if entry.filename.startswith(root + "_CodeSignature/"):
                        continue
                    content = updated if entry.filename == executable else source.read(entry)
                    target.writestr(entry, content)
                entry = zipfile.ZipInfo(root + "Frameworks/ExternalDownloads.dylib")
                entry.compress_type = zipfile.ZIP_DEFLATED
                entry.external_attr = 0o100755 << 16
                target.writestr(entry, lib)
        with zipfile.ZipFile(temporary) as result:
            if result.testzip() is not None:
                raise ValueError("Output archive verification failed")
        os.replace(temporary, output)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ipa")
    parser.add_argument("library")
    parser.add_argument("output")
    args = parser.parse_args()
    pack(args.ipa, args.library, args.output)
    print("Created", args.output)
