# SPDX-License-Identifier: AGPL-3.0-or-later
"""The myVW Canada preset reads the Home screen of a real 2024 Atlas, and only that."""
from __future__ import annotations

import time
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

from custom_components.vag_connect.companion.channel import CompanionChannel
from custom_components.vag_connect.companion.client import CompanionClient, _home_assistant_time_zone
from custom_components.vag_connect.companion.presets import PRESETS, preset_reads_sync_time
from custom_components.vag_connect.companion.screen import (
    find_sync_time,
    has_anchor,
    parse_ui_dump,
    read_fields,
)

FIXTURES = Path(__file__).parent / "fixtures" / "companion_myvw"
PRESET = PRESETS["volkswagen_ca"]
OTHER_SCREENS = sorted(p.name for p in FIXTURES.glob("*.xml") if not p.name.startswith("01_"))
EST = timezone(timedelta(hours=-5))


def _nodes(name: str):
    return parse_ui_dump((FIXTURES / name).read_text(encoding="utf-8"))


def _read(name: str) -> dict[str, object]:
    return read_fields(_nodes(name), PRESET)


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


def test_home_updated_at_line_is_the_time_as_the_app_shows_it() -> None:
    assert find_sync_time(_nodes("01_Home.xml"), PRESET) == datetime(2026, 11, 23, 21, 57)


@pytest.mark.parametrize("name", OTHER_SCREENS)
def test_no_other_captured_screen_has_a_sync_time(name: str) -> None:
    # The Service screen's timestamp line says "Updating", which is not a time.
    assert find_sync_time(_nodes(name), PRESET) is None


def test_which_presets_read_a_sync_time() -> None:
    assert preset_reads_sync_time("volkswagen")
    assert preset_reads_sync_time("volkswagen_ca")
    assert not preset_reads_sync_time("cupra")
    assert not preset_reads_sync_time("nonsense")


def test_home_assistant_zone_is_available_to_the_client() -> None:
    assert _home_assistant_time_zone() is not None


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


def _channel(wall: datetime, tz) -> CompanionChannel:
    phone = _Phone((FIXTURES / "01_Home.xml").read_text(encoding="utf-8"))
    return CompanionChannel(
        phone, PRESET, time_fn=time.monotonic,
        wall_clock_fn=lambda: wall.timestamp(), local_tz_fn=lambda: tz,
    )


async def test_the_updated_at_line_becomes_the_car_sync_time_in_utc() -> None:
    channel = _channel(datetime(2026, 11, 24, 10, 0, tzinfo=EST), EST)

    fields = await channel.read()

    # 9:57 p.m. on 11/23 in a UTC-5 zone is 02:57 UTC the next day.
    assert fields["companion_app_synced_at"] == datetime(2026, 11, 24, 2, 57, tzinfo=timezone.utc)
    assert channel.source_data_age_s == 12 * 3600 + 3 * 60


async def test_without_a_known_zone_the_line_is_not_used() -> None:
    channel = _channel(datetime(2026, 11, 24, 10, 0, tzinfo=EST), None)

    fields = await channel.read()

    assert "companion_app_synced_at" not in fields
    assert channel.source_data_age_s is None


async def test_a_time_in_the_future_means_the_zones_differ_and_is_ignored() -> None:
    # Read as 10 p.m. on 11/23 the line would be 2 hours ahead of "now".
    channel = _channel(datetime(2026, 11, 23, 19, 57, tzinfo=EST), EST)

    fields = await channel.read()

    assert "companion_app_synced_at" not in fields
    assert fields["odometer_km"] == 59726  # the other Home values still read


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
