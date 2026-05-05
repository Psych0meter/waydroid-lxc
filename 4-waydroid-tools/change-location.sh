#!/usr/bin/env bash
if [ "$#" -ne 2 ]; then
    echo "Usage: ./change-location.sh <latitude> <longitude>"
    echo "Example: ./change-location.sh 48.8584 2.2945"
    exit 1
fi

python3 fake_gps.py $1 $2
echo "Location updated to $1, $2."
