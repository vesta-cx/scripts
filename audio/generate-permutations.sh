#!/usr/bin/env bash
# Generate all codec+bitrate permutations from a lossless audio source.
#
# Usage: ./generate-permutations.sh <input-file> [output-dir]
#
# Accepts any lossless format (FLAC, WAV, AIFF, ALAC, etc.).
# Runs ffmpeg jobs in parallel (one per CPU core).
#
# Output naming: {basename}_{codec}_{bitrate}.{ext}
#   - flac_0.flac        (lossless)
#   - opus_{br}.ogg      (Ogg container)
#   - mp3_{br}.mp3
#   - aac_{br}.m4a       (MP4 container)
#
# Codecs & bitrates match the quality-survey quality_options table:
#   flac: 0 (lossless)
#   opus: 320, 256, 192, 160, 128, 96, 64, 48, 32
#   mp3:  320, 256, 192, 160, 128, 96, 64, 48, 32
#   aac:  256, 192, 160, 128, 96, 64, 48, 32

set -euo pipefail

if [[ $# -lt 1 ]]; then
	echo "Usage: $0 <input-file> [output-dir]"
	exit 1
fi

INPUT="$1"
OUT="${2:-static/sample-audio}"
BASENAME=$(basename "${INPUT%.*}")
JOBS=$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)

if [[ ! -f "$INPUT" ]]; then
	echo "Error: input file '$INPUT' not found"
	exit 1
fi

mkdir -p "$OUT"

encode() {
	local codec="$1" br="$2" ext="$3"
	shift 3
	local extra=("$@")
	local outfile="$OUT/${BASENAME}_${codec}_${br}.${ext}"
	echo "Encoding: ${codec}/${br}kbps -> $(basename "$outfile")"
	ffmpeg -y -i "$INPUT" "${extra[@]}" "$outfile" 2>/dev/null
}

export -f encode
export INPUT OUT BASENAME

# Build job list and run in parallel
{
	echo "flac 0 flac -c:a flac"
	for br in 320 256 192 160 128 96 64 48 32; do
		echo "opus $br ogg -c:a libopus -b:a ${br}k"
	done
	for br in 320 256 192 160 128 96 64 48 32; do
		echo "mp3 $br mp3 -c:a libmp3lame -b:a ${br}k"
	done
	for br in 256 192 160 128 96 64 48 32; do
		echo "aac $br m4a -c:a aac -b:a ${br}k"
	done
} | xargs -P "$JOBS" -I {} bash -c 'encode {}'

echo "Done. Generated $(ls -1 "$OUT" | wc -l) files in $OUT/ (parallel=$JOBS)"
