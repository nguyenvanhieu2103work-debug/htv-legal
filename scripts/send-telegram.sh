#!/usr/bin/env bash
# Gửi kịch bản quay qua Telegram Bot API, chia theo các mốc "========== TIN n/N =========="
#
# Cần 2 biến môi trường:
#   TELEGRAM_BOT_TOKEN  token của bot (vd bot @tro_ly_htv_bot)
#   TELEGRAM_CHAT_ID    chat id đích (xem cách lấy ở --help)
#
# Dùng:
#   TELEGRAM_BOT_TOKEN=... TELEGRAM_CHAT_ID=... ./scripts/send-telegram.sh <file.txt>
#   ./scripts/send-telegram.sh --dry-run <file.txt>     # chỉ in ra, không gửi
#   ./scripts/send-telegram.sh --chat-id                # liệt kê chat id khả dụng
set -euo pipefail

API="https://api.telegram.org"
DRY=0

usage() {
  cat <<'USAGE'
send-telegram.sh — gửi file kịch bản qua Telegram, chia nhiều tin

  send-telegram.sh <file.txt>              gửi (cần TELEGRAM_BOT_TOKEN + TELEGRAM_CHAT_ID)
  send-telegram.sh --dry-run <file.txt>    in từng tin + số ký tự, không gửi
  send-telegram.sh --chat-id               in các chat id bot đang thấy (cần TELEGRAM_BOT_TOKEN)

Lấy chat id: nhắn một tin bất kỳ cho bot trong Telegram, rồi chạy --chat-id.
File được cắt tại các dòng "========== TIN n/N =========="; mỗi phần gửi thành
một tin riêng, giới hạn 4096 ký tự/tin của Telegram.
USAGE
}

case "${1:-}" in
  -h|--help|"") usage; exit 0 ;;
  --chat-id)
    : "${TELEGRAM_BOT_TOKEN:?chưa đặt TELEGRAM_BOT_TOKEN}"
    curl -sS "$API/bot${TELEGRAM_BOT_TOKEN}/getUpdates" \
      | python3 -c 'import json,sys
d=json.load(sys.stdin)
if not d.get("ok"): sys.exit("Telegram trả lỗi: %s" % d.get("description"))
seen={}
for u in d.get("result",[]):
    c=(u.get("message") or u.get("channel_post") or {}).get("chat")
    if c: seen[c["id"]]=c.get("title") or " ".join(filter(None,[c.get("first_name"),c.get("last_name")])) or c.get("username","")
if not seen: sys.exit("Chưa thấy chat nào. Nhắn cho bot một tin rồi chạy lại.")
for k,v in seen.items(): print(f"{k}\t{v}")'
    exit 0 ;;
  --dry-run) DRY=1; shift ;;
esac

FILE="${1:?thiếu đường dẫn file}"
[[ -r "$FILE" ]] || { echo "không đọc được $FILE" >&2; exit 1; }

if [[ $DRY -eq 0 ]]; then
  : "${TELEGRAM_BOT_TOKEN:?chưa đặt TELEGRAM_BOT_TOKEN}"
  : "${TELEGRAM_CHAT_ID:?chưa đặt TELEGRAM_CHAT_ID}"
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
awk -v dir="$WORK" '
  /^========== TIN /{ n++; out=sprintf("%s/part-%02d.txt", dir, n); next }
  n>0 { print > out }
' "$FILE"

shopt -s nullglob
PARTS=("$WORK"/part-*.txt)
(( ${#PARTS[@]} )) || { echo "không tìm thấy mốc '========== TIN' nào trong $FILE" >&2; exit 1; }

i=0
for p in "${PARTS[@]}"; do
  i=$((i+1))
  len=$(wc -m < "$p" | tr -d ' ')
  if (( len > 4096 )); then
    echo "tin $i dài $len ký tự, vượt hạn 4096 của Telegram — cắt nhỏ thêm trước khi gửi" >&2
    exit 1
  fi
  if [[ $DRY -eq 1 ]]; then
    printf '\n----- tin %d/%d (%s ký tự) -----\n' "$i" "${#PARTS[@]}" "$len"
    cat "$p"
    continue
  fi
  resp=$(curl -sS -X POST "$API/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
    --data-urlencode "disable_web_page_preview=true" \
    --data-urlencode "text@$p")
  if ! printf '%s' "$resp" | grep -q '"ok":true'; then
    echo "tin $i gửi thất bại: $resp" >&2
    exit 1
  fi
  echo "tin $i/${#PARTS[@]} đã gửi ($len ký tự)"
  sleep 1   # tránh rate limit của Telegram
done
