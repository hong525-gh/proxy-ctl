#!/usr/bin/env python3
"""List the country codes inside Xray's geosite.dat / geoip.dat.

Why: a routing rule may only reference a code the loaded database actually has.
A typo or a code that never existed (`geosite:office`, 2026-11-04 outage) makes
`xray run -test` fail, and a restart then takes the proxy down. Building a
manifest up front lets `vpnctl validate` reject the candidate before anything
is restarted.

Both databases are protobuf messages of the same shape:

    GeoSiteList { repeated GeoSite geosite = 1 }   # field 1, wire type 2
    GeoIPList   { repeated GeoIP   geoip   = 1 }   # field 1, wire type 2
    GeoSite/GeoIP { string country_code = 1; ... } # first nested field, string

Only the codes are read, so a tiny protobuf-lite walker is enough — no
dependency, no network. Anything unparseable is skipped rather than guessed.

Usage:
    geo-manifest.py <geosite.dat|geoip.dat> [-o out.txt]

Prints the codes (uppercase, one per line, sorted) to stdout or -o.
Exits 2 if the file cannot be read or yields no codes, so callers can tell
"manifest unavailable" from "manifest is empty".
"""

import sys


def read_varint(buf, i):
    shift = 0
    value = 0
    while True:
        if i >= len(buf):
            raise ValueError("truncated varint")
        b = buf[i]
        i += 1
        value |= (b & 0x7F) << shift
        if not b & 0x80:
            return value, i
        shift += 7
        if shift > 63:
            raise ValueError("varint too long")


def fields(buf):
    """Yield (field_number, wire_type, value) for one protobuf message."""
    i = 0
    n = len(buf)
    while i < n:
        key, i = read_varint(buf, i)
        field, wire = key >> 3, key & 7
        if wire == 0:
            value, i = read_varint(buf, i)
        elif wire == 2:
            length, i = read_varint(buf, i)
            if i + length > n:
                raise ValueError("truncated length-delimited field")
            value = buf[i:i + length]
            i += length
        elif wire == 1:
            value = buf[i:i + 8]
            i += 8
        elif wire == 5:
            value = buf[i:i + 4]
            i += 4
        else:
            raise ValueError("unsupported wire type %d" % wire)
        yield field, wire, value


def codes(path):
    with open(path, "rb") as fh:
        buf = fh.read()
    out = set()
    # A damaged or padded tail must not discard the codes already read: stop quietly and
    # let the caller judge the result (vpnctl ignores a manifest that looks too small).
    try:
        for field, wire, entry in fields(buf):
            # The list message wraps each database entry in field 1.
            if field != 1 or wire != 2:
                continue
            try:
                sub = list(fields(entry))
            except ValueError:
                continue
            if not sub or sub[0][0] != 1 or sub[0][1] != 2:
                continue
            code = sub[0][2]
            if not isinstance(code, (bytes, bytearray)):
                continue
            text = code.decode("utf-8", "strict")
            # Country/region codes are short uppercase ASCII; skip anything else
            # (some builds carry comments or attributes in later fields).
            if text and len(text) <= 32 and all(c.isascii() for c in text):
                out.add(text.upper())
    except (ValueError, UnicodeDecodeError):
        pass
    return sorted(out)


def main(argv):
    args = [a for a in argv[1:]]
    out_path = None
    if "-o" in args:
        idx = args.index("-o")
        if idx + 1 >= len(args):
            sys.stderr.write("geo-manifest: -o needs a path\n")
            return 1
        out_path = args[idx + 1]
        del args[idx:idx + 2]
    if len(args) != 1:
        sys.stderr.write("usage: geo-manifest.py <dat-file> [-o out.txt]\n")
        return 1
    try:
        found = codes(args[0])
    except (OSError, ValueError, UnicodeDecodeError) as exc:
        sys.stderr.write("geo-manifest: cannot read %s: %s\n" % (args[0], exc))
        return 2
    if not found:
        sys.stderr.write("geo-manifest: no codes found in %s\n" % args[0])
        return 2
    text = "\n".join(found) + "\n"
    if out_path:
        with open(out_path, "w", encoding="utf-8") as fh:
            fh.write(text)
    else:
        sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
