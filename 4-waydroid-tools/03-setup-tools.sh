#!/usr/bin/env bash
set -e

echo "Downloading Quackdoc's spoof-device.sh..."
wget -qO spoof-device.sh https://raw.githubusercontent.com/Quackdoc/waydroid-scripts/main/spoof-device.sh
chmod +x spoof-device.sh

echo "Downloading ayasa520's fake_gps.py..."
wget -qO fake_gps.py https://raw.githubusercontent.com/ayasa520/waydroid_stuff/main/fake_gps.py
chmod +x fake_gps.py

echo "Tools downloaded and ready!"
