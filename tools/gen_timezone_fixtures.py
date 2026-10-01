#!/usr/bin/env python3
"""Optional libc characterization; never a dependency of pure Zig tests.

--capture explicitly freezes installed TZif bytes and libc observations.
--check (default) replays the frozen bytes/specs, not current zoneinfo data.
"""
import argparse
import calendar
import hashlib
import json
import os
from pathlib import Path
import platform
import struct
import time

ROOT = Path(__file__).resolve().parent.parent
FIXTURE = ROOT / "src/zig/util/testdata/timezone-libc.json"
WORK = ROOT / "build/timezone-characterization"
ZONES = ["America/New_York", "Australia/Lord_Howe", "Europe/Dublin", "Etc/UTC"]
SPECS = [
    "UTC0", "XYZ5", "<+0545>-5:45",
    "EST5EDT,M3.2.0/2,M11.1.0/2",
    "AST-10ADST-10:30,M10.1.0/2,M4.1.0/2",
    "IST-1GMT0,M10.5.0,M3.5.0/1",
    "STD0DST,J60/0,J300/0", "STD0DST,59/0,300/0",
    "EST5EDT,0/0,J365/25",
]
INSTANTS = [
    -62167219200, -3786825600, -2208988800, -1, 0, 1, 536870912,
    1530395348, 1610712000, 1626350400, 1615705199, 1615705200,
    1636264799, 1636264800, 2147483647, 2147483648,
]
# Full daily future-tail sweep plus sub-second-boundary probes around US DST.
INSTANTS += [calendar.timegm((2100, 1, 1, 12, 0, 0)) + day * 86400 for day in range(365)]
INSTANTS += [calendar.timegm((2020, 2, 28, 23, 59, 59)) + i for i in [0, 1, 86400, 86401]]
INSTANTS += [calendar.timegm((2021, 1, 1, 0, 0, 0)) + i for i in [-1, 0, 17999, 18000]]
INSTANTS += [calendar.timegm((1969, 7, 1, 12, 0, 0))]
for month, week, hour in [(3, 2, 7), (11, 1, 6)]:
    sundays = [row[6] for row in calendar.monthcalendar(2100, month) if row[6]]
    transition = calendar.timegm((2100, month, sundays[week - 1], hour, 0, 0))
    INSTANTS += [transition - 1, transition, transition + 1]


def sections(data):
    counts = struct.unpack(">6I", data[20:44])
    ut, std, leaps, times, types, chars = counts
    if data[4] in (ord("2"), ord("3")):
        second = 44 + times * 5 + types * 6 + chars + leaps * 8 + std + ut
        ut, std, leaps, times, types, chars = struct.unpack(">6I", data[second + 20:second + 44])
        start, width, fmt = second + 44, 8, ">q"
    else:
        start, width, fmt = 44, 4, ">i"
    transitions = [struct.unpack(fmt, data[start + i * width:start + (i + 1) * width])[0] for i in range(times)]
    leap_start = start + times * (width + 1) + types * 6 + chars
    records = []
    for i in range(leaps):
        position = leap_start + i * (width + 4)
        records.append((struct.unpack(fmt, data[position:position + width])[0],
                        struct.unpack(">i", data[position + width:position + width + 4])[0]))
    return transitions, records


def observe(tz, instants, leaps=()):
    os.environ["TZ"] = tz
    time.tzset()
    result = []
    for instant in sorted(set(instants)):
        correction = 0
        for raw, next_correction in leaps:
            if instant < raw - correction:
                break
            correction = next_correction
        local = time.localtime(instant + correction)
        result.append({
            "instant": instant, "offset": local.tm_gmtoff,
            "is_dst": local.tm_isdst != 0, "abbreviation": local.tm_zone,
        })
    return result


def capture():
    zoneinfo = Path("/usr/share/zoneinfo")
    fixture = {
        "schema_version": 1,
        "tzdata_version": (zoneinfo / "tzdata.zi").read_text().splitlines()[0],
        "libc": " ".join(platform.libc_ver()),
        "tzif": [], "posix": [],
    }
    for i, name in enumerate(ZONES):
        data = (zoneinfo / name).read_bytes()
        path = WORK / f"capture-{i}.tzif"
        path.write_bytes(data)
        times, leaps = sections(data)
        normalized = []
        for raw in times:
            correction = 0
            for leap_time, next_correction in leaps:
                if leap_time > raw:
                    break
                correction = next_correction
            normalized.append(raw - correction)
        instants = INSTANTS + [t + delta for t in normalized for delta in [-1, 0, 1]]
        fixture["tzif"].append({
            "name": name, "sha256": hashlib.sha256(data).hexdigest(), "bytes_hex": data.hex(),
            "leap_aware": bool(leaps), "samples": observe(":" + str(path), instants, leaps),
        })
    for i, all_dst in enumerate([False, True]):
        # Independent struct-pack vectors distinguish glibc's type-selection
        # heuristic from a reader that always assumes type zero before history.
        names = b"DST\0STD\0"
        data = b"TZif\0" + bytes(15) + struct.pack(">6I", 0, 0, 0, 1, 2, len(names))
        data += struct.pack(">iB", 1000, 0)
        data += struct.pack(">iBBiBB", 3600, 1, 0, 0, int(all_dst), 4) + names
        path = WORK / f"pre-first-{i}.tzif"
        path.write_bytes(data)
        fixture["tzif"].append({
            "name": f"synthetic/pre-first-{'all-dst' if all_dst else 'standard'}",
            "sha256": hashlib.sha256(data).hexdigest(), "bytes_hex": data.hex(),
            "samples": observe(":" + str(path), [-1, 0, 999, 1000, 1001]),
        })
    header = b"TZif2" + bytes(15) + struct.pack(">6I", 0, 0, 0, 0, 1, 4)
    data = (header + struct.pack(">iBB", 0, 0, 0) + b"STD\0") * 2
    data += b"\nSTD0DST,M3.2.0,M11.1.0\n"
    path = WORK / "empty-table.tzif"
    path.write_bytes(data)
    fixture["tzif"].append({
        "name": "synthetic/empty-table-footer",
        "sha256": hashlib.sha256(data).hexdigest(), "bytes_hex": data.hex(),
        "samples": observe(":" + str(path), INSTANTS),
    })
    for i, corrections in enumerate([(1, 2), (-1, -2)]):
        names = b"STD\0DST\0"
        data = b"TZif\0" + bytes(15) + struct.pack(">6I", 0, 0, 2, 2, 2, len(names))
        data += struct.pack(">iiBB", 78796802, 94694402, 1, 0)
        data += struct.pack(">iBBiBB", 0, 0, 0, 3600, 1, 4) + names
        data += struct.pack(">iiii", 78796800, corrections[0], 94694401, corrections[1])
        _, leaps = sections(data)
        path = WORK / f"leap-aware-{i}.tzif"
        path.write_bytes(data)
        instants = [0] + [t + d for t in [78796800, 94694400] for d in range(-2, 7)]
        fixture["tzif"].append({
            "name": f"synthetic/leap-aware-{'positive' if i == 0 else 'negative'}",
            "sha256": hashlib.sha256(data).hexdigest(), "bytes_hex": data.hex(),
            "leap_aware": True, "samples": observe(":" + str(path), instants, leaps),
        })
    for spec in SPECS:
        fixture["posix"].append({"spec": spec, "samples": observe(spec, INSTANTS)})
    FIXTURE.parent.mkdir(parents=True, exist_ok=True)
    FIXTURE.write_text(json.dumps(fixture, indent=2) + "\n")
    print(f"captured {FIXTURE} ({fixture['tzdata_version']}; {fixture['libc']})")


def check():
    encoded = FIXTURE.read_bytes()
    expected = FIXTURE.with_suffix(".SHA256SUMS").read_text().split()[0]
    if hashlib.sha256(encoded).hexdigest() != expected:
        raise ValueError("frozen timezone oracle SHA256 mismatch")
    fixture = json.loads(encoded)
    count = 0
    for i, zone in enumerate(fixture["tzif"]):
        data = bytes.fromhex(zone["bytes_hex"])
        if hashlib.sha256(data).hexdigest() != zone["sha256"]:
            raise ValueError(f"{zone['name']}: frozen TZif SHA256 mismatch")
        path = WORK / f"replay-{i}.tzif"
        path.write_bytes(data)
        _, leaps = sections(data)
        actual = observe(":" + str(path), [s["instant"] for s in zone["samples"]], leaps)
        if actual != zone["samples"]:
            raise ValueError(f"{zone['name']}: libc observations changed")
        count += len(actual)
    for zone in fixture["posix"]:
        actual = observe(zone["spec"], [s["instant"] for s in zone["samples"]])
        if actual != zone["samples"]:
            raise ValueError(f"{zone['spec']}: libc observations changed")
        count += len(actual)
    print(f"verified {count} frozen observations using {' '.join(platform.libc_ver())}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--capture", action="store_true")
    mode.add_argument("--check", action="store_true")
    args = parser.parse_args()
    WORK.mkdir(parents=True, exist_ok=True)
    previous = os.environ.get("TZ")
    try:
        capture() if args.capture else check()
    finally:
        if previous is None:
            os.environ.pop("TZ", None)
        else:
            os.environ["TZ"] = previous
        time.tzset()


if __name__ == "__main__":
    main()
