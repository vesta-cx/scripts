#!/usr/bin/env bash
# Generate codec+bitrate permutations from a lossless audio source.
#
# Usage:
#   ./generate-permutations.sh <input> [output-dir]
#   ./generate-permutations.sh -i <input> -o <output-dir>
#   ./generate-permutations.sh -i <input> -c opus,mp3 -b 128,96,64
#
# Options:
#   -i, --input     Input file (lossless: FLAC, WAV, AIFF, ALAC)
#   -o, --output    Output directory (default: current directory)
#   -c, --codecs    Comma-separated codecs to generate (default: flac,opus,mp3,aac)
#   -b, --bitrates  Comma-separated bitrates in kbps (default: 320,256,192,160,128,96,64,48,32)
#   -h, --help      Show this help
#
# Output structure:
#   <output-dir>/
#     flac/{basename}_0.flac
#     opus/{basename}_{bitrate}.ogg
#     mp3/{basename}_{bitrate}.mp3
#     aac/{basename}_{bitrate}.m4a
#
# Notes:
#   - FLAC ignores the bitrate list (always outputs as lossless / bitrate=0)
#   - Runs ffmpeg jobs in parallel (one per CPU core)

set -euo pipefail

# -- Defaults ------------------------------------------------------------------

ALL_CODECS="flac,opus,mp3,aac"
ALL_BITRATES="320,256,192,160,128,96,64,48,32"
LOSSLESS_FORMATS="flac alac wavpack wav aiff pcm_s16le pcm_s24le pcm_s32le pcm_f32le pcm_s16be pcm_s24be pcm_s32be"

INPUT=""
OUTPUT="."
CODECS=""
BITRATES=""

# -- Helpers -------------------------------------------------------------------

usage() {
	cat <<-'USAGE'
		Usage:
		  generate-permutations.sh <input> [output-dir]
		  generate-permutations.sh -i <input> [-o <output-dir>] [-c codecs] [-b bitrates]

		Options:
		  -i, --input     Input file (must be lossless: FLAC, WAV, AIFF, ALAC, etc.)
		  -o, --output    Output directory (default: current directory)
		  -c, --codecs    Comma-separated codecs (default: flac,opus,mp3,aac)
		  -b, --bitrates  Comma-separated bitrates in kbps (default: 320,256,192,160,128,96,64,48,32)
		  -h, --help      Show this help

		Examples:
		  generate-permutations.sh track.flac
		  generate-permutations.sh -i track.wav -o ./out -c opus,mp3 -b 128,96,64
	USAGE
	exit "${1:-0}"
}

die() {
	echo "Error: $1" >&2
	exit 1
}

check_lossless() {
	local codec
	codec=$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of csv=p=0 "$1" 2>/dev/null)
	for fmt in $LOSSLESS_FORMATS; do
		[[ "$codec" == "$fmt" ]] && return 0
	done
	die "Input should be lossless (detected codec: ${codec:-unknown}). Accepted formats: FLAC, WAV, AIFF, ALAC."
}

# -- Parse args ----------------------------------------------------------------

POSITIONAL=()
while [[ $# -gt 0 ]]; do
	case "$1" in
	-i | --input)
		INPUT="$2"
		shift 2
		;;
	-o | --output)
		OUTPUT="$2"
		shift 2
		;;
	-c | --codecs)
		CODECS="$2"
		shift 2
		;;
	-b | --bitrates)
		BITRATES="$2"
		shift 2
		;;
	-h | --help)
		usage 0
		;;
	-*)
		die "Unknown option: $1"
		;;
	*)
		POSITIONAL+=("$1")
		shift
		;;
	esac
done

# Positional fallback: <input> [output]
if [[ -z "$INPUT" && ${#POSITIONAL[@]} -ge 1 ]]; then
	INPUT="${POSITIONAL[0]}"
fi
if [[ "$OUTPUT" == "." && ${#POSITIONAL[@]} -ge 2 ]]; then
	OUTPUT="${POSITIONAL[1]}"
fi

[[ -z "$INPUT" ]] && usage 1
[[ ! -f "$INPUT" ]] && die "Input file '$INPUT' not found"

# Apply defaults
CODECS="${CODECS:-$ALL_CODECS}"
BITRATES="${BITRATES:-$ALL_BITRATES}"

# -- Validate ------------------------------------------------------------------

command -v ffmpeg >/dev/null 2>&1 || die "ffmpeg is required but not found in PATH"
command -v ffprobe >/dev/null 2>&1 || die "ffprobe is required but not found in PATH"
check_lossless "$INPUT"

# -- Setup ---------------------------------------------------------------------

BASENAME=$(basename "${INPUT%.*}")
JOBS=$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)

IFS=',' read -ra CODEC_LIST <<<"$CODECS"
IFS=',' read -ra BITRATE_LIST <<<"$BITRATES"

# Create codec subdirectories
for codec in "${CODEC_LIST[@]}"; do
	mkdir -p "$OUTPUT/$codec"
done

# -- Encode --------------------------------------------------------------------

encode() {
	local codec="$1" br="$2" ext="$3"
	shift 3
	local extra=("$@")
	local outfile="$OUTPUT/${codec}/${BASENAME}_${br}.${ext}"
	echo "Encoding: ${codec}/${br}kbps -> ${codec}/$(basename "$outfile")"
	ffmpeg -y -i "$INPUT" "${extra[@]}" "$outfile" 2>/dev/null
}

export -f encode
export INPUT OUTPUT BASENAME

# Build job list
build_jobs() {
	for codec in "${CODEC_LIST[@]}"; do
		case "$codec" in
		flac)
			echo "flac 0 flac -c:a flac"
			;;
		opus)
			for br in "${BITRATE_LIST[@]}"; do
				echo "opus $br ogg -c:a libopus -b:a ${br}k"
			done
			;;
		mp3)
			for br in "${BITRATE_LIST[@]}"; do
				echo "mp3 $br mp3 -c:a libmp3lame -b:a ${br}k"
			done
			;;
		aac)
			for br in "${BITRATE_LIST[@]}"; do
				echo "aac $br m4a -c:a aac -b:a ${br}k"
			done
			;;
		*)
			echo "Warning: unknown codec '$codec', skipping" >&2
			;;
		esac
	done
}

TOTAL=$(build_jobs | wc -l | tr -d ' ')
echo "Generating $TOTAL files from '$(basename "$INPUT")' into '$OUTPUT/' (parallel=$JOBS)"
echo ""

build_jobs | xargs -P "$JOBS" -I {} bash -c 'encode {}'

echo ""
echo "Done. Generated $TOTAL files in $OUTPUT/"
