#!/usr/bin/env python3
"""
Test sender for the Stride UDP receiver.

Streams synthetic accelerometer / gyroscope / heart-rate / GPS / rate packets
to the phone so you can verify the app before the real watch firmware is ready.

Usage:
    python3 test_sender.py <PHONE_IP> [--port 12345] [--rate 50] [--format json] [--no-gps]

Find <PHONE_IP> in iOS Settings > Wi-Fi > (i) next to your network.
Phone and computer must be on the same Wi-Fi network.
"""
import argparse
import math
import socket
import time


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("host", help="IP address of the iPhone running Stride")
    ap.add_argument("--port", type=int, default=12345)
    ap.add_argument("--rate", type=float, default=50.0, help="packets per second")
    ap.add_argument("--format", choices=["json", "csv"], default="json")
    ap.add_argument("--no-gps", action="store_true",
                     help="omit lat/long (simulates 'waiting for GPS fix')")
    ap.add_argument("--lat", type=float, default=37.3346, help="base latitude")
    ap.add_argument("--long", type=float, default=-122.0090, help="base longitude")
    ap.add_argument("--imu-hz", type=float, default=50.0, help="reported IMU sampling rate")
    args = ap.parse_args()

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    period = 1.0 / args.rate
    t0 = time.time()

    print(f"Streaming {args.format} to {args.host}:{args.port} at {args.rate} Hz "
          f"(Ctrl-C to stop)")
    try:
        while True:
            t = time.time()
            elapsed = t - t0
            # gentle synthetic motion
            ax = 0.4 * math.sin(elapsed * 1.7)
            ay = 0.3 * math.sin(elapsed * 1.1 + 1)
            az = 0.96 + 0.05 * math.sin(elapsed * 2.3)
            gx = 60 * math.sin(elapsed * 1.3)
            gy = 40 * math.sin(elapsed * 0.9 + 2)
            gz = 20 * math.sin(elapsed * 1.9)
            hr = 88 + 6 * math.sin(elapsed * 0.25)
            # tiny synthetic drift so lat/long aren't perfectly static
            lat = args.lat + 0.00003 * math.sin(elapsed * 0.05)
            lon = args.long + 0.00003 * math.cos(elapsed * 0.05)
            send_hz = args.rate

            if args.format == "json":
                # [t, ax, ay, az, gx, gy, gz, hr, lat, long, imuRateHz, sendRateHz]
                if args.no_gps:
                    payload = (
                        f'[{t * 1000:.0f},{ax:.4f},{ay:.4f},{az:.4f},'
                        f'{gx:.2f},{gy:.2f},{gz:.2f},{hr:.1f}]'
                    )
                else:
                    payload = (
                        f'[{t * 1000:.0f},{ax:.4f},{ay:.4f},{az:.4f},'
                        f'{gx:.2f},{gy:.2f},{gz:.2f},{hr:.1f},'
                        f'{lat:.6f},{lon:.6f},{args.imu_hz:.1f},{send_hz:.1f}]'
                    )
            else:  # csv: t,ax,ay,az,gx,gy,gz,hr[,lat,long,imuRateHz,sendRateHz]
                if args.no_gps:
                    payload = (
                        f"{t * 1000:.0f},{ax:.4f},{ay:.4f},{az:.4f},"
                        f"{gx:.2f},{gy:.2f},{gz:.2f},{hr:.1f}"
                    )
                else:
                    payload = (
                        f"{t * 1000:.0f},{ax:.4f},{ay:.4f},{az:.4f},"
                        f"{gx:.2f},{gy:.2f},{gz:.2f},{hr:.1f},"
                        f"{lat:.6f},{lon:.6f},{args.imu_hz:.1f},{send_hz:.1f}"
                    )

            sock.sendto(payload.encode("utf-8"), (args.host, args.port))
            time.sleep(period)
    except KeyboardInterrupt:
        print("\nStopped.")


if __name__ == "__main__":
    main()
