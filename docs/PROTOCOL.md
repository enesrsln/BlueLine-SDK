# BlueLine BLE Protocol

Byte-level description of the BlueLine BLE protocol, version 1, implemented
by BlueLine device firmware 0.3.0 and newer. The SDKs implement all of it; read this
only to write your own client.

Byte order: all multi-byte fields are **little-endian**, except EEG samples,
which are **signed 24-bit big-endian**.

## Discovery

Advertising packet: flags + complete name, `BlueLine-<model>` (e.g. `BlueLine-4`).
Scan response:

- Complete list of 128-bit service UUIDs: the BlueLine service.
- Manufacturer specific data, company `0xFFFF`:
  `'B' 'L' model(u8) chip_id_low(u32)`. `model` is the model number (4 = BlueLine-4). `chip_id_low`
  is the low 32 bits of the hardware id, so a scanner can tell devices apart
  before connecting.

Advertising: 152.5 ms for 60 s, then 1022.5 ms indefinitely.

## Services

| Service                    | UUID                                   |
|----------------------------|----------------------------------------|
| BlueLine                   | `8E7C0001-7B4E-4C1E-AF19-22A6F38D9B40` |
| Battery                    | `0x180F`                               |
| Device Information         | `0x180A`                               |

Device Information:

| Characteristic         | Value                                                   |
|------------------------|---------------------------------------------------------|
| Manufacturer (0x2A29)  | `BrainBit`                                              |
| Model (0x2A24)         | `BlueLine-<model>`, e.g. `BlueLine-4`                   |
| Serial (0x2A25)        | factory serial, or the hardware id as 16 hex chars (see below) |
| Firmware (0x2A26)      | `MAJOR.MINOR.PATCH`, e.g. `0.3.0`                       |
| Software (0x2A28)      | `BlueLine protocol 1`                                   |

BlueLine characteristics (`8E7Cxxxx-7B4E-4C1E-AF19-22A6F38D9B40`):

| xxxx   | Name     | Properties     | Length    |
|--------|----------|----------------|-----------|
| `0002` | Info     | read           | 32        |
| `0003` | Signal   | notify         | 20..236   |
| `0004` | MEMS     | notify         | 16        |
| `0005` | Status   | read, notify   | 20        |
| `0006` | Control  | write, notify  | 1..20     |

No pairing or bonding. Pairing requests are rejected.

## Device identity

- **Serial number**: if a factory serial was written, DIS returns it and Info
  flag bit0 is set. Otherwise DIS returns the 64-bit hardware id as 16
  uppercase hex chars. Either value is stable across firmware updates.
- **Hardware id**: unique per device, always available in Info bytes 24..31.

## Info (read, 32 bytes)

| Offset | Type | Field                                                   |
|--------|------|---------------------------------------------------------|
| 0      | u8   | protocol version (1)                                    |
| 1      | u8   | model number (e.g. 4)                                   |
| 2      | u8   | flags: bit0 = DIS serial is a factory serial            |
| 3      | u8   | EEG channels (C; 4 on BlueLine-4)                       |
| 4..6   | u8x3 | firmware major, minor, patch                            |
| 7      | u8   | ADC bits (24)                                           |
| 8      | u16  | ADC rate Hz (1000)                                      |
| 10     | u16  | signal output rate Hz (250)                             |
| 12     | u8   | decimation: ADC samples averaged per output sample (4)  |
| 13     | u8   | current gain (default 6)                                |
| 14     | u32  | ADC reference, microvolts                               |
| 18     | u16  | MEMS rate Hz (100, nominal)                             |
| 20     | u8   | max samples per signal packet (19)                      |
| 21     | u8   | signal header bytes (8)                                 |
| 22     | u16  | features: bit0 signal, bit1 MEMS, bit2 resist, bit3 identify, bit4 set gain |
| 24     | u64  | hardware id                                             |

Gain changes update this value. With ATT MTU 23 a read needs a long read;
most BLE stacks do this on their own.

Microvolts: `uV = code * vref_uV / (gain * 8388608)`.

## Control (write request + notify)

Subscribe to Control notifications first, then write a request. Each request
produces exactly one notification:

```
request : [opcode] [params...]
response: [opcode] [result] [payload...]
```

| Opcode | Command        | Params   | Response payload        |
|--------|----------------|----------|-------------------------|
| `0x01` | START_SIGNAL   | -        | session u16             |
| `0x02` | STOP_SIGNAL    | -        | -                       |
| `0x03` | START_MEMS     | -        | -                       |
| `0x04` | STOP_MEMS      | -        | -                       |
| `0x05` | START_RESIST   | -        | (reserved, NOT_SUPPORTED) |
| `0x06` | STOP_RESIST    | -        | (reserved, NOT_SUPPORTED) |
| `0x10` | SET_GAIN       | gain u8  | gain u8, session u16    |
| `0x20` | IDENTIFY       | -        | - (LED blinks green 2 s) |

Results: 0 OK, 1 NOT_SUPPORTED, 2 INVALID_PARAM, 3 INVALID_STATE, 4 BUSY,
5 HW_FAULT. A request written while the previous one is still being processed
is discarded and answered with opcode `0xFF`, result BUSY.

- `START_SIGNAL` while running is a no-op and returns the current session.
- `SET_GAIN` accepts 1, 2, 4, 6, 8, 12, 24. While streaming it restarts
  acquisition, so a new session starts and the sample index restarts at 0.
  Never mix samples from different sessions: the scale is different.
- Disconnecting stops signal and MEMS acquisition.
- Gain resets to 6 at every boot.

## Signal (notify)

Data flows only after `START_SIGNAL` **and** with notifications enabled.

```
[0]    flags   bit0 GAP: samples before first_index were lost
[1]    N       sample count (1..19)
[2..3] session u16
[4..7] first_index u32   index of the first sample in this packet
[8..]  N x C x 3 bytes: CH1..CHC as int24 big-endian (C from Info)
```

- Sample `i` in the packet has index `first_index + i`. A packet never spans a
  gap. Index = output sample number since `START_SIGNAL`, at 250 Hz, so
  `t = index / 250 s` relative to the session start.
- An index jump means samples were lost: either on the device (BLE queue full
  or ADC frames missed, both counted in Status) or because notifications were
  off. Do not interpolate silently; mark the gap.
- Nominal batch is 5 samples (20 ms). Larger packets (up to 19 samples, MTU
  permitting) only appear while catching up after congestion.
- Each output sample is the rounded mean of 4 consecutive 1 kHz ADC frames. A
  block with a missing frame is dropped, never averaged from fewer frames.
  Mean-of-4 is not a designed anti-alias filter; apply proper filtering on
  the host.

## MEMS (notify, 16 bytes)

Data flows only after `START_MEMS` with notifications enabled.

| Offset | Type  | Field                                              |
|--------|-------|----------------------------------------------------|
| 0      | u16   | session (current signal session)                   |
| 2      | u32   | MEMS sample index since `START_MEMS`               |
| 6      | u32   | signal index at read time, `0xFFFFFFFF` if signal stopped |
| 10     | i16x3 | X, Y, Z raw accelerometer counts, 3.9 mg per count  |

Values are raw (gravity included), so the host can see orientation. The signal index
gives approximate alignment with EEG. It is not a hardware-synchronised
timestamp.

## Status (read + notify, 20 bytes)

| Offset | Type | Field                                                    |
|--------|------|----------------------------------------------------------|
| 0      | u8   | state: 0 idle, 1 signal                                  |
| 1      | u8   | flags: bit0 MEMS on, bit1 TX blocked, bit2 EEG sensor fault, bit3 accelerometer fault |
| 2      | u8   | battery %                                                |
| 3      | u8   | gain                                                     |
| 4      | u16  | effective ATT MTU                                        |
| 6      | u16  | session                                                  |
| 8      | u32  | signal samples dropped (BLE queue full), this session    |
| 12     | u32  | ADC frames lost before processing, this session          |
| 16     | u32  | MEMS samples dropped                                     |

State, flag and gain changes notify immediately. Counter-only changes
notify at most once per second.

## Recommended client sequence

1. Scan for the service UUID and connect. Request MTU 247 if the platform
   lets you (iOS negotiates on its own).
2. Read DIS (serial, firmware) and Info.
3. Enable notifications on Control, Status, Signal (and MEMS if needed).
4. Write `START_SIGNAL` (and `START_MEMS`). Keep the session from the response.
5. Decode Signal packets; drop packets whose session differs from the active one.
6. Write `STOP_SIGNAL` before disconnecting.
