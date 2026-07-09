#!/usr/bin/env python3
"""
Test sender for the Stride UDP receiver.

Streams synthetic accelerometer / gyroscope / heart-rate packets to the phone
so you can verify the app before the real watch firmware is ready.

Usage:
    python3 test_sender.py <PHONE_IP> [--port 12345] [--rate 50] [--format json]

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
    args = ap.parse_args()

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    period = 1.0 / args.rate
    t0 = time.time()
    hr = 88.0

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

            if args.format == "json":
                payload = (
                    f'{{"t":{t:.3f},"ax":{ax:.4f},"ay":{ay:.4f},"az":{az:.4f},'
                    f'"gx":{gx:.2f},"gy":{gy:.2f},"gz":{gz:.2f},"hr":{hr:.1f}}}'
                )
            else:  # csv: t,ax,ay,az,gx,gy,gz,hr
                payload = (
                    f"{t:.3f},{ax:.4f},{ay:.4f},{az:.4f},"
                    f"{gx:.2f},{gy:.2f},{gz:.2f},{hr:.1f}"
                )

            sock.sendto(payload.encode("utf-8"), (args.host, args.port))
            time.sleep(period)
    except KeyboardInterrupt:
        print("\nStopped.")


if __name__ == "__main__":
    main()
