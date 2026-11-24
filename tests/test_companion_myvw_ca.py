# SPDX-License-Identifier: AGPL-3.0-or-later
"""The myVW Canada preset reads the Home screen of a real 2024 Atlas, and only that."""
from __future__ import annotations

import time
from pathlib import Path

import pytest

from custom_components.vag_connect.companion.channel import CompanionChannel
from custom_components.vag_connect.companion.client import CompanionClient
from custom_components.vag_connect.companion.presets import PRESETS
from custom_components.vag_connect.companion.screen import has_anchor, parse_ui_dump, read_fields

FIXTURES = Path(__file__).parent / "fixtures" / "companion_myvw"
PRESET = PRESETS["volkswagen_ca"]
OTHER_SCREENS = sorted(p.name for p in FIXTURES.glob("*.xml") if not p.name.startswith("01_"))


def _read(name: str) -> dict[str, object]:
    return read_fields(parse_ui_dump((FIXTURES / name).read_text(encoding="utf-8")), PRESET)


def test_preset_is_the_canadian_package_and_read_only() -> None:
    assert PRESET.package == "com.vw.carnet.releaseca"
    assert PRESET.package != "com.vw.carnet.release"  # the US app was never captured
    assert not PRESET.verified and not PRESET.writable
    assert PRESET.actions == () and PRESET.nav_reads == ()


def test_home_reads_range_odometer_and_lock() -> None:
    assert _read("01_Home.xml") == {
        "combustion_range_km": 540,
        "odometer_km": 59726,
        "doors_locked": True,
    }


@pytest.mark.parametrize("name", OTHER_SCREENS)
def test_no_other_captured_screen_reads_anything(name: str) -> None:
    # The Service screen also says "8,300 km", the trip screens "10 km", and the
    # Doors sheet has a "Lock" button: none of them may be taken for a reading.
    assert _read(name) == {}


def test_anchor_is_the_home_screen_top_or_scrolled_and_nothing_else() -> None:
    home = {"01_Home.xml", "02_Home-scrolled-down.xml"}
    for path in sorted(FIXTURES.glob("*.xml")):
        nodes = parse_ui_dump(path.read_text(encoding="utf-8"))
        assert has_anchor(nodes, PRESET) is (path.name in home), path.name


class _Phone:
    connected = True

    def __init__(self, dump: str) -> None:
        self._dump = dump

    async def connect(self) -> None:
        return None

    async def foreground_app(self, package: str) -> None:
        assert package == "com.vw.carnet.releaseca"

    async def current_app_version(self, package: str) -> str | None:
        return "2026.10.23-9809"

    async def dump_ui(self) -> str:
        return self._dump


async def test_client_maps_the_home_screen_onto_a_petrol_vehicle() -> None:
    client = CompanionClient.__new__(CompanionClient)
    client._brand = "volkswagen_ca"
    client._vin = "1V2FR2CA5RC000000"
    client._transport = _Phone((FIXTURES / "01_Home.xml").read_text(encoding="utf-8"))
    client._channel = CompanionChannel(client._transport, PRESET, time_fn=time.monotonic)
    client._last_data = None
    client.on_tokens_changed = None

    data = await client.get_status("1V2FR2CA5RC000000")

    assert (data.odometer_km, data.combustion_range_km, data.doors_locked) == (59726, 540, True)
    assert data.has_combustion and not data.has_battery
    assert data.companion_writes_enabled is False
