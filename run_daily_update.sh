#!/bin/bash
# Cập nhật dữ liệu sông/hồ + sạt lở. Chạy tay hoặc qua cron (ví dụ mỗi ngày 13:00 GMT+7).

set -e
cd "$(dirname "$0")"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting daily update..."

pip install -r requirements.txt -q
python water_export_cli.py
python landslide_export_cli.py

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Done."
