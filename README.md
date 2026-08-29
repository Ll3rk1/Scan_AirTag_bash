# AirTag Scan Enhanced

`AirTag-scan-enhanced.sh` scans Linux Bluetooth LE advertisements for the
Apple manufacturer-data signatures used by registered Find My devices and
unregistered AirTags. It reports the advertiser MAC, RSSI, a per-device
exponential moving average (EMA), an approximate distance, proximity, count,
and the complete advertising payload.

The scanner is based conceptually on Larry Pesce's
[`AirTag-scan.sh`](https://github.com/haxorthematrix/AirTag-tools/blob/main/AirTag-scan.sh).

## Requirements

- Linux with a Bluetooth LE adapter
- Bash 4 or newer
- BlueZ legacy tools: `hcitool`, `hcidump` (and preferably `hciconfig`)
- `awk`, `sed`, `grep`, `date`, and `sleep`
- `tput` and an interactive terminal for `--table`
- Root access or `sudo` permission for Bluetooth scanning

On Debian/Ubuntu, the BlueZ package names vary by release. Start with:

```bash
sudo apt update
sudo apt install bluez bluez-hcidump
```

## Run

```bash
chmod +x AirTag-scan-enhanced.sh
sudo ./AirTag-scan-enhanced.sh --pretty
```

Other examples:

```bash
sudo ./AirTag-scan-enhanced.sh --table -i hci0
sudo ./AirTag-scan-enhanced.sh --raw
sudo ./AirTag-scan-enhanced.sh --csv > airtags.csv
sudo ./AirTag-scan-enhanced.sh --pretty --rssi1m -62 --path-loss 2.6 --ema 0.20
```

Run `./AirTag-scan-enhanced.sh --help` for every option.

CSV columns are:

```text
timestamp,mac,type,rssi,rssi_filtered,distance,proximity,count,payload
```

## Calibration and limitations

The distance uses the log-distance model:

```text
distance = 10 ^ ((RSSI_AT_1M - filtered_RSSI) / (10 * PATH_LOSS))
```

Measure `RSSI_AT_1M` at exactly one meter with the intended receiver. A
`PATH_LOSS` value near `2.0` is a useful open-space starting point; indoor
environments often need a higher value. Adjust `--ema` toward `0` for more
smoothing or toward `1` for faster response.

BLE RSSI distance is inherently approximate and can be strongly affected by
walls, people, reflections, interference, antenna orientation, and receiver
hardware. It is not UWB distance and is not Apple Precision Finding.
