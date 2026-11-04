"""Exceptions raised by the BlueLine SDK. Every failure is a :class:`BlueLineError`."""

from __future__ import annotations

from typing import Optional


class BlueLineError(Exception):
    """Base class of every SDK error."""


class BluetoothUnavailable(BlueLineError):
    """Bluetooth is off, missing or not permitted."""


class ConnectionFailed(BlueLineError):
    """Connecting or a GATT operation failed."""


class UnsupportedDevice(BlueLineError):
    """The device does not speak BlueLine protocol v1 (firmware < 0.3.0)."""


class Timeout(BlueLineError):
    """The device did not respond in time."""


class NotConnected(BlueLineError):
    """A command was issued while the device is not connected."""


class Disconnected(BlueLineError):
    """The connection dropped while a request was pending."""


class InvalidParameter(BlueLineError, ValueError):
    """An argument is out of range (for example gain 5)."""


class CommandFailed(BlueLineError):
    """The device answered a control request with an error result."""

    def __init__(self, command, result, raw_result: Optional[int] = None):
        self.command = command
        self.result = result
        self.raw_result = raw_result if raw_result is not None else (int(result) if result is not None else None)
        name = result.name if result is not None else f"result {self.raw_result}"
        super().__init__(f"Command {command.name} failed ({name}).")
