# Warning Water Dashboard

Dashboard giám sát **mực nước sông/hồ** và **cảnh báo sạt lở, lũ quét** tại Việt Nam. Dữ liệu được crawl từ VNDMS, e15 (Viện Thủy lợi) và NCHMF.

---

## Cài đặt

```bash
pip install -r requirements.txt
```

**Dependencies:** `requests`, `pandas`, `python-dateutil`, `tqdm`, `urllib3`

---

## Cấu hình

- **`config_stations.json`**: Danh sách hồ chứa và trạm sông được crawl.
  - `lakes`: mapping `LakeCode` (UUID) → `name`, `basin_recode`, `province_recode`
  - `stations`: mapping mã trạm (số) → `name`, `basin_recode`
- Chỉ các ID có trong config mới được thu thập. Thêm/bớt trạm hoặc hồ bằng cách sửa file này.

---

## Crawl dữ liệu Sông & Hồ (`water_export_cli.py`)

### Chuẩn bị

- **Cửa sổ thời gian (GMT+7):**
  - **Chưa có** `data/water_data_full_combined.csv`: fetch **7 ngày** gần nhất.
  - **Đã có** CSV: đọc cột `Thời gian (UTC)`, lấy ngày mới nhất → fetch từ ngày đó đến hôm nay. Nếu lỗi đọc thì fallback 7 ngày.
- **HTTP:** `requests.Session` + retry (tối đa 3 lần) cho 500/502/503/504. Timeout 60s (list/lake), 15s (detail).
- **Timezone:** `Asia/Ho_Chi_Minh` (GMT+7).

### Bước 1: Lấy danh sách trạm sông (VNDMS)

| Mục | Chi tiết |
|-----|----------|
| **API** | `GET https://vndms.dmptc.gov.vn/water_level` |
| **Tham số** | `lv=0`, `lv=1`, `lv=2`, `lv=3` (4 request) |
| **Headers** | `User-Agent`, `Referer`, `Origin` giả lập truy cập từ VNDMS |

- Response dạng GeoJSON: `features[]` với `properties.popupInfo` (HTML) và `geometry` (Point).
- Parse:
  - **Mã trạm:** regex `Mã trạm:\s*<b>(\d+)</b>` trong `popupInfo`. Bỏ qua nếu không có hoặc `sid` không nằm trong `STATION_IDS` (config).
  - **Sông:** `Sông:\s*<b>(.*?)</b>`
  - **Tọa độ:** `geometry.coordinates` → `[x, y]`
- Kết quả: `stations[sid] = { river, name, x, y }` chỉ cho các trạm trong config.

### Bước 2: Lấy chi tiết mực nước từng trạm (VNDMS)

| Mục | Chi tiết |
|-----|----------|
| **API** | `POST https://vndms.dmc.gov.vn/home/detailRain` |
| **Body** | `id=<sid>`, `timeSelect=7`, `source=Water`, `fromDate=`, `toDate=` |

- Response gồm ngưỡng (`bao_dong1`, `bao_dong2`, `bao_dong3`, `gia_tri_lu_lich_su`, `nam_lu_lich_su`) và chuỗi thời gian (`labels`, `value`).
- **Xử lý:**
  1. Lấy ngưỡng qua `get_first_num` (parse float, bỏ giá trị ≤ 0).
  2. Zip `labels` và `value` → từng cặp (thời gian, mực nước).
  3. **Parse thời gian** `parse_river_dt`:
     - Format mới: `0h 15/11` → giờ, ngày, tháng. Xử lý năm nếu tháng 12 / tháng 1.
     - Format cũ: `7h30/12` → giờ, phút, ngày; tháng = tháng hiện tại.
  4. Chỉ giữ điểm có `date >= DEFAULT_START_DATE`.
  5. **Cảnh báo:** `classify_exceed` → 0..4 (dưới BĐ1 → trên lũ lịch sử), `alert_name_from_value`, `calculate_alert_diff`.
  6. **Recode:** `config_stations.json` override tên, lưu vực; không có thì dùng API. Tọa độ lấy từ bước 1.

Mỗi cặp (time, level) hợp lệ → một dòng **River** vào `final_rows`.

### Bước 3: Lấy dữ liệu hồ chứa (e15)

| Mục | Chi tiết |
|-----|----------|
| **API** | `POST http://e15.thuyloivietnam.vn/CanhBaoSoLieu/ATCBDTHo` |
| **Body** | `time=YYYY-MM-DD 00:00:00,000`, `ishothuydien=0` |

- Gọi **một request mỗi ngày** từ `DEFAULT_START_DATE` đến `DEFAULT_END_DATE`.
- Response: mảng JSON, mỗi phần tử một hồ. Chỉ giữ `LakeCode in LAKE_IDS` (config).
- **Thời gian:** `ThoiGianCapNhat` (ms) → `ms_to_dt_local` → GMT+7. Loại bản ghi có `date < DEFAULT_START_DATE`.
- **Recode:** `config` → `basin_recode`, `name`, `province_recode`. Map các trường (dung tích, %, Q đến/xả, tọa độ, …) sang output.

Mỗi bản ghi hồ thỏa điều kiện → một dòng **Lake** vào `final_rows`.

### Bước 4: Gộp và ghi CSV

- Tạo `DataFrame` từ `final_rows`, sort theo `type`, `basin`, `name`, `timestamp_utc`.
- Đổi tên cột sang tiếng Việt (ví dụ `Mã trạm/LakeCode`, `Thời gian (UTC)`, …).
- **Ghi file:**
  - Chưa có `water_data_full_combined.csv`: ghi mới.
  - Đã có: đọc CSV cũ → `concat` với dữ liệu mới → **dedup** theo `(type, Mã trạm/LakeCode, Thời gian (UTC))`, `keep="last"` → sort → ghi đè.

### Chạy

```bash
python water_export_cli.py
```

---

## Crawl dữ liệu Sạt lở / Lũ quét (`landslide_export_cli.py`)

### Chuẩn bị

| Mục | Chi tiết |
|-----|----------|
| **API** | `POST https://luquetsatlo.nchmf.gov.vn/LayerMapBox/getDSCanhbaoSLLQ` |
| **Body** | `sogiodubao=6`, `date=YYYY-MM-DD HH:MM:SS` (giờ hiện tại GMT+7, làm tròn về `:00:00`) |
| **Retry** | Tối đa 3 lần, timeout 45s, delay 2s rồi tăng dần |

### Bước 1: Gửi request và parse

1. `now = datetime.now(TZ_LOCAL)`, làm tròn về giờ → `date_str`.
2. `POST` với `sogiodubao=6`, `date=date_str`.
3. Parse JSON (list). Với mỗi `row`:
   - Lấy `provinceName_2cap`, `commune_id_2cap`, `commune_name_2cap` (strip).
   - Nếu `commune_name_2cap` bắt đầu bằng `"P. "` thì bỏ prefix (để khớp bản đồ).
   - Lấy `nguycosatlo`, `nguycoluquet` (Rất cao / Cao / Trung bình).
   - Thêm bản ghi `{ time, commune_id_2cap, commune_name_2cap, provinceName_2cap, nguycosatlo, nguycoluquet }` vào `records`.

### Bước 2: Dedup theo mức độ nguy cơ

- `severity_score(row) = max(SEVERITY_RANK[nguycosatlo], SEVERITY_RANK[nguycoluquet])` với Rất cao=3, Cao=2, Trung bình=1.
- Group theo `commune_id_2cap`, giữ **một dòng** có điểm cao nhất mỗi nhóm.
- Sort theo `provinceName_2cap`, `commune_name_2cap` → ghi **đè** `data/landslide.csv`.

### Chạy

```bash
python landslide_export_cli.py
```

---

## Luồng tổng quát

### Sông & Hồ

```
load config_stations.json (LAKE_IDS, STATION_IDS)
    ↓
xác định DEFAULT_START_DATE, DEFAULT_END_DATE (từ CSV cũ hoặc 7 ngày)
    ↓
GET water_level?lv=0..3 → danh sách trạm (chỉ STATION_IDS)
    ↓
POST /ATCBDTHo từng ngày → dữ liệu hồ (chỉ LAKE_IDS)
    ↓
POST detailRain từng trạm → parse labels/value, cảnh báo, recode
    ↓
DataFrame → merge với CSV cũ (nếu có) → dedup → to_csv
```

### Sạt lở

```
now GMT+7, làm tròn giờ
    ↓
POST getDSCanhbaoSLLQ { sogiodubao: 6, date }
    ↓
parse list → chuẩn hóa tên xã (bỏ "P. ")
    ↓
groupby commune_id_2cap, giữ max severity → to_csv overwrite
```

---

## Output

| File | Mô tả |
|------|--------|
| `data/water_data_full_combined.csv` | Sông + hồ, merge tăng dần, dedup theo (type, mã, thời gian) |
| `data/landslide.csv` | Cảnh báo sạt lở/lũ quét theo xã, ghi đè mỗi lần chạy |

---

## CI (GitHub Actions)

- Workflow `.github/workflows/main.yml`:
  - **Schedule:** cron mỗi giờ (phút 0 UTC).
  - **Steps:** checkout → Python 3.11, `pip install -r requirements.txt` → `water_export_cli` → `landslide_export_cli` → tạo email summary (diff) → create PR (branch `data-update-patch`) → gửi email (cần `MAIL_USERNAME`, `MAIL_PASSWORD`).
- Có thể chạy tay qua **workflow_dispatch**.

---

## Tóm tắt nhanh

| | Sông & Hồ | Sạt lở |
|---|-----------|--------|
| **Nguồn** | VNDMS + e15 | NCHMF |
| **Cách lấy** | GET list → POST từng trạm; POST hồ theo ngày | 1 POST (date + sogiodubao) |
| **Lọc** | Chỉ ID trong `config_stations.json` | Không lọc ID; dedup theo xã |
| **Cửa sổ** | 7 ngày hoặc từ last date → hôm nay | Mốc “hiện tại” theo giờ |
| **Ghi file** | Merge + dedup | Overwrite |

---

## Dashboard

- **`index.html`**: Bản đồ + sidebar, lọc lưu vực, biểu đồ.
- **`index_redesign.html`**: Filter tỉnh/lưu vực/vị trí, danh sách cảnh báo chi tiết.

Mở file HTML trong trình duyệt (hoặc qua static server). Dữ liệu đọc từ `data/` và `geo/`.
