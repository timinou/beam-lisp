"""Regenerate bounded offset evidence from the pinned files, using zoneinfo."""
from datetime import datetime, timezone
from pathlib import Path
from zoneinfo import ZoneInfo
import json
import struct

root = Path(__file__).parent
references = []
for name in ("UTC", "Africa_Casablanca", "America_New_York"):
    data = (root / name).read_bytes()

    def header(at):
        return struct.unpack(">6I", data[at + 20:at + 44])

    def size(counts, width):
        universal, standard, leaps, times, types, chars = counts
        return times * (width + 1) + types * 6 + chars + leaps * (width + 4) + universal + standard

    start = 44 + size(header(0), 4)
    universal, standard, leaps, times_count, types, chars = header(start)
    times = struct.unpack(">" + "q" * times_count, data[start + 44:start + 44 + 8 * times_count])
    with (root / name).open("rb") as stream:
        zone = ZoneInfo.from_file(stream)
    points = set()
    for moment in times:
        for delta in (-1, 0, 1):
            if -2208988800 <= moment + delta <= 2145916800:
                points.add(moment + delta)
    for year in range(2020, 2031):
        for month in range(1, 13):
            points.add(int(datetime(year, month, 15, 12, tzinfo=timezone.utc).timestamp()))
    for moment in sorted(points):
        # This reader intentionally reports a recurring footer as unmodelled
        # at the last table transition. Exercise that boundary as UNKNOWN in
        # zone_test; do not count it as a supported-reference offset match.
        if name == "America_New_York" and moment >= times[-1]:
            continue
        local = datetime.fromtimestamp(moment, timezone.utc).astimezone(zone)
        references.append({"zone": name, "instant": moment, "offset": int(local.utcoffset().total_seconds())})
(root / "offset-reference.json").write_text(json.dumps(references, separators=(",", ":")) + "\n")
print(f"{len(references)} independent offset checks")
