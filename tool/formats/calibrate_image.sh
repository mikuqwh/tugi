#!/usr/bin/env bash
# Calibration for the IMAGE size estimate: bytes per pixel, per format and
# quality, measured on three deliberately different sources.
#
# bytes ~ width * height * bpp(format, quality). The estimator in
# lib/utils/size_estimate.dart uses the min/max bpp this prints, so it gives a
# range instead of a fake precise number. Re-run after changing encoders.
set -u
cd "$(dirname "$0")"
rm -rf imgcal && mkdir -p imgcal && cd imgcal || exit 1

# Three 480x270 sources: photo-like noise, vector-ish graphic, flat colour.
ffmpeg -hide_banner -loglevel error -y -f lavfi \
  -i "gradients=size=480x270,noise=alls=22:allf=t" -frames:v 1 photo.png
ffmpeg -hide_banner -loglevel error -y -f lavfi \
  -i "testsrc2=size=480x270" -frames:v 1 graphic.png
ffmpeg -hide_banner -loglevel error -y -f lavfi \
  -i "color=c=royalblue:size=480x270" -frames:v 1 flat.png

# A transparent source, to see what alpha costs / drops.
ffmpeg -hide_banner -loglevel error -y -f lavfi \
  -i "color=c=red@0.5:size=480x270,format=rgba" -frames:v 1 alpha.png

px=$((480 * 270))
echo "source,format,quality,bytes,bpp"
run() {
  local src="$1" fmt="$2" label="$3" cargs="$4"
  local out="o.${fmt}"
  # shellcheck disable=SC2086
  ffmpeg -hide_banner -loglevel error -y -i "$src" ${cargs:-} "$out" 2>/dev/null
  local b
  b=$(stat -c %s "$out" 2>/dev/null || echo 0)
  python -c "print('%s,%s,%s,%d,%.4f' % ('$src','$fmt','$label',$b,$b/$px))"
  rm -f "$out"
}

for src in photo.png graphic.png flat.png; do
  run "$src" png p100 "-c:v png"
  run "$src" jpg q85 "-c:v mjpeg -q:v 4"
  run "$src" jpg q60 "-c:v mjpeg -q:v 12"
  run "$src" webp q85 "-c:v libwebp -quality 85"
  run "$src" webp q60 "-c:v libwebp -quality 60"
  run "$src" avif crf30 "-c:v libaom-av1 -cpu-used 8 -crf 30"
  run "$src" bmp none ""
  run "$src" tiff none ""
done

echo
echo "-- alpha source --"
run alpha.png png p100 "-c:v png"
run alpha.png webp q85 "-c:v libwebp -quality 85"
run alpha.png jpg q85 "-c:v mjpeg -q:v 4"
