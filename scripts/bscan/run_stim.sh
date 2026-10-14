#!/bin/bash
# run_stim.sh <label> <ncaptures> <interval_s> [remote command run on the Pluto while capturing]
# Captures go to <label>.txt in the current directory. The remote command (if any) starts 1 s
# after the capture begins; the capture outlives it by design (make ncaptures*interval long enough).
set -u
cd "$(dirname "$0")"
label=$1; n=$2; iv=$3; shift 3
python3 -I xvcjtag.py xc7z010_clg400.json "$n" "$label.txt" "$iv" > "$label.log" 2>&1 &
cap=$!
sleep 1
if [ $# -gt 0 ]; then
  sshpass -p analog ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR root@192.168.2.1 "$@" > "$label.remote" 2>&1
  echo "remote rc=$?"
fi
wait $cap
tail -2 "$label.log"
