#!/usr/bin/env bash
# Generate HLS fMP4 test streams (Opus, FLAC, AAC) from a lossless audio source.
#
# Usage:
#   ./generate-hls-fmp4-test.sh <input> [-o <output-dir>]
#   ./generate-hls-fmp4-test.sh input.flac -o tools/test-pages/public
#
# Options:
#   -o, --output  Output directory (default: ./hls-test-output)
#   -t, --time    Segment duration in seconds (default: 6)
#   -d, --duration  Max output duration in seconds (default: 90 = 1m30s)
#   -h, --help    Show this help
#
# Output structure:
#   <output>/opus/   init.mp4, seg0.m4s, seg1.m4s, ..., playlist.m3u8, full.mp4 (for Cast)
#   <output>/flac/   init.mp4, seg0.m4s, seg1.m4s, ..., playlist.m3u8, full.mp4
#   <output>/aac/    init.mp4, seg0.m4s, seg1.m4s, ..., playlist.m3u8, full.mp4
#   <output>/mp3/    seg0.ts, seg1.ts, ..., playlist.m3u8 (MPEG-TS), full.mp3 (Cast)
#
# MP3 uses MPEG-TS segments (.ts); others use fMP4 (.m4s).
# full.mp4 / full.flac / full.mp3: single-file for Cast.
# full.flac = raw FLAC container (test codec vs container: MP4+FLAC vs raw FLAC).
#
# The AAC stream is a known-good control for Safari. If AAC fails, the test
# setup is broken — fix before drawing conclusions about Opus/FLAC.
#
# After generation the script prints a summary and reminds you to inspect
# the manifests for #EXT-X-MAP and CODECS attributes.

set -euo pipefail

# -- Defaults ------------------------------------------------------------------

OUTPUT="./hls-test-output"
SEGMENT_TIME=6
DURATION=90
INPUT=""

# -- Helpers -------------------------------------------------------------------

usage() {
	cat <<-'USAGE'
		Usage:
		  generate-hls-fmp4-test.sh <input> [-o <output-dir>] [-t <segment-seconds>] [-d <duration-seconds>]

		Options:
		  -o, --output  Output directory (default: ./hls-test-output)
		  -t, --time    Segment duration in seconds (default: 6)
		  -d, --duration  Max output duration in seconds (default: 90 = 1m30s)
		  -h, --help    Show this help

		Examples:
		  generate-hls-fmp4-test.sh track.flac
		  generate-hls-fmp4-test.sh track.flac -o tools/test-pages/public
		  generate-hls-fmp4-test.sh track.flac -o out -t 4 -d 60
	USAGE
	exit "${1:-0}"
}

die() {
	echo "Error: $1" >&2
	exit 1
}

# -- Parse args ----------------------------------------------------------------

while [[ $# -gt 0 ]]; do
	case "$1" in
	-o | --output)
		OUTPUT="$2"
		shift 2
		;;
	-t | --time)
		SEGMENT_TIME="$2"
		shift 2
		;;
	-d | --duration)
		DURATION="$2"
		shift 2
		;;
	-h | --help)
		usage 0
		;;
	-*)
		die "Unknown option: $1"
		;;
	*)
		if [[ -z "$INPUT" ]]; then
			INPUT="$1"
		else
			die "Unexpected argument: $1"
		fi
		shift
		;;
	esac
done

[[ -n "$INPUT" ]] || die "No input file specified. Run with -h for help."
[[ -f "$INPUT" ]] || die "Input file not found: $INPUT"
command -v ffmpeg >/dev/null 2>&1 || die "ffmpeg not found in PATH"
command -v ffprobe >/dev/null 2>&1 || die "ffprobe not found in PATH"

# -- Encode --------------------------------------------------------------------

LOG="$OUTPUT/.encode.log"

encode_hls() {
	local codec_name="$1"
	shift
	local codec_args=("$@")
	local dir="$OUTPUT/$codec_name"

	mkdir -p "$dir"
	echo "[$codec_name] Encoding..."

	if ffmpeg -y -i "$INPUT" -t "$DURATION" -vn -map 0:a "${codec_args[@]}" \
		-f hls -hls_time "$SEGMENT_TIME" -hls_list_size 0 -hls_playlist_type vod \
		-hls_flags independent_segments \
		-hls_segment_type fmp4 \
		-hls_segment_filename "$dir/seg%d.m4s" \
		-hls_fmp4_init_filename init.mp4 \
		"$dir/playlist.m3u8" 2>>"$LOG"; then
		echo "[$codec_name] Done."
	else
		echo "[$codec_name] FAILED — check $LOG" >&2
		return 1
	fi
}

encode_hls_ts() {
	local codec_name="$1"
	shift
	local codec_args=("$@")
	local dir="$OUTPUT/$codec_name"

	mkdir -p "$dir"
	echo "[$codec_name] Encoding (MPEG-TS)..."

	if ffmpeg -y -i "$INPUT" -t "$DURATION" -vn -map 0:a "${codec_args[@]}" \
		-f hls -hls_time "$SEGMENT_TIME" -hls_list_size 0 -hls_playlist_type vod \
		-hls_flags independent_segments \
		-hls_segment_type mpegts \
		-hls_segment_filename "$dir/seg%d.ts" \
		"$dir/playlist.m3u8" 2>>"$LOG"; then
		echo "[$codec_name] Done."
	else
		echo "[$codec_name] FAILED — check $LOG" >&2
		return 1
	fi
}

mkdir -p "$OUTPUT"
: >"$LOG"

FAILED=0

encode_hls "opus" -c:a libopus -b:a 128k -vbr on -ar 48000 || ((FAILED++))
encode_hls "flac" -strict -2 -c:a flac || ((FAILED++))
encode_hls "aac" -c:a aac -b:a 128k || ((FAILED++))

encode_hls_ts "mp3" -c:a libmp3lame -b:a 128k || ((FAILED++))

# -- Single-file MP4 for Cast (AV receivers often don't support HLS) ------------

echo ""
echo "Creating full.mp4 for Cast fallback..."
for codec in opus flac aac; do
	dir="$OUTPUT/$codec"
	case "$codec" in
		opus) codec_args=(-c:a libopus -b:a 128k -ar 48000) ;;
		flac) codec_args=(-strict -2 -c:a flac) ;;
		aac)  codec_args=(-c:a aac -b:a 128k) ;;
	esac
	if ffmpeg -y -i "$INPUT" -t "$DURATION" -vn -map 0:a "${codec_args[@]}" \
		-movflags +faststart "$dir/full.mp4" 2>>"$LOG"; then
		echo "[$codec] full.mp4 done."
	else
		echo "[$codec] full.mp4 FAILED" >&2
		((FAILED++)) || true
	fi
done

# -- FLAC raw (.flac) for Cast codec-vs-container test --------------------------

echo ""
echo "Creating flac full.flac (raw container) for Cast test..."
if ffmpeg -y -i "$INPUT" -t "$DURATION" -vn -map 0:a -c:a flac "$OUTPUT/flac/full.flac" 2>>"$LOG"; then
	echo "[flac] full.flac done."
else
	echo "[flac] full.flac FAILED" >&2
	((FAILED++)) || true
fi

# -- MP3 full.mp3 for Cast ------------------------------------------------------

echo ""
echo "Creating mp3 full.mp3 for Cast..."
if ffmpeg -y -i "$INPUT" -t "$DURATION" -vn -map 0:a -c:a libmp3lame -b:a 128k "$OUTPUT/mp3/full.mp3" 2>>"$LOG"; then
	echo "[mp3] full.mp3 done."
else
	echo "[mp3] full.mp3 FAILED" >&2
	((FAILED++)) || true
fi

# -- Summary -------------------------------------------------------------------

echo ""
echo "=== Summary ==="
echo "Output: $OUTPUT"
echo ""

for codec in opus flac aac; do
	manifest="$OUTPUT/$codec/playlist.m3u8"
	fullmp4="$OUTPUT/$codec/full.mp4"
	if [[ -f "$manifest" ]]; then
		seg_count=$(grep -c '^seg' "$manifest" 2>/dev/null || echo 0)
		has_map=$(grep -c '#EXT-X-MAP' "$manifest" 2>/dev/null || echo 0)
		cast_files=""
		[[ -f "$fullmp4" ]] && cast_files="full.mp4"
		[[ "$codec" = "flac" && -f "$OUTPUT/flac/full.flac" ]] && cast_files="${cast_files}${cast_files:+, }full.flac"
		[[ -n "$cast_files" ]] && cast_files=" (Cast: $cast_files)"
		echo "  $codec: $seg_count segments, EXT-X-MAP present: $( [[ "$has_map" -gt 0 ]] && echo "yes" || echo "NO — problem!" )${cast_files}"
	else
		echo "  $codec: MISSING manifest"
	fi
done
manifest="$OUTPUT/mp3/playlist.m3u8"
fullmp3="$OUTPUT/mp3/full.mp3"
if [[ -f "$manifest" ]]; then
	seg_count=$(grep -c '^seg' "$manifest" 2>/dev/null || echo 0)
	mp3_ok=""
	[[ -f "$fullmp3" ]] && mp3_ok=", full.mp3 (Cast)"
	echo "  mp3: $seg_count segments (MPEG-TS)${mp3_ok}"
else
	echo "  mp3: MISSING manifest"
fi

echo ""
if [[ "$FAILED" -gt 0 ]]; then
	echo "$FAILED codec(s) failed. Check $LOG"
	exit 1
fi

echo "Inspect manifests for CODECS attributes:"
echo "  grep -i codecs $OUTPUT/*/playlist.m3u8"
echo ""
echo "Next: cd to your test-pages dir, run 'pnpm dev -- --host', test on device."
