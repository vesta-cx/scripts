#!/usr/bin/env bash
# Generate codec+bitrate permutations from lossless audio source(s).
#
# Usage:
#   ./generate-permutations.sh <input> [output-dir]
#   ./generate-permutations.sh -i <input-file-or-dir> -o <output-dir>
#   ./generate-permutations.sh -i ./lossless/ -c opus,mp3 -b 128,96,64
#
# Options:
#   -i, --input     Input file or directory (lossless: FLAC, WAV, AIFF, ALAC)
#   -o, --output    Output directory (default: current directory)
#   -c, --codecs    Comma-separated codecs to generate (default: flac,opus,mp3,aac)
#   -b, --bitrates  Comma-separated bitrates in kbps (default: 320,256,192,160,128,96,64,48,32)
#   -h, --help      Show this help
#
# When input is a directory, all audio files in it are processed recursively.
# Non-lossless files are skipped with a warning.
#
# Output structure (source-first, mirrors input directory structure):
#   Single file:
#     <output>/{codec}/{basename}_{codec}_{bitrate}.{ext}
#
#   Directory (mirrors input structure):
#     <output>/{relative-path}/{codec}/{basename}_{codec}_{bitrate}.{ext}
#
#   Examples:
#     Single: ./gen.sh take-five.flac -o out
#       out/opus/take-five_opus_128.ogg
#
#     Directory: ./gen.sh -i albums/ -o out
#       Input:  albums/jazz/take-five.flac
#       Output: out/jazz/opus/take-five_opus_128.ogg
#               out/jazz/mp3/take-five_mp3_128.mp3
#               out/jazz/flac/take-five_flac_0.flac
#
# Notes:
#   - FLAC ignores the bitrate list (always outputs as lossless / bitrate=0)
#   - Runs ffmpeg jobs in parallel (one per CPU core)
#   - Embedded artwork is stripped to save storage (many candidates per source = duplicated art).
#     Text metadata (artist, title, album) is re-added from source via -metadata.
#   - When ARTIST is "Various Artists" (Bandcamp compilations), parses artist from filename
#     (pattern: "... - NNN artistname - title") and overrides ARTIST in outputs
#   - MP3 outputs include ID3v2.3 tags (-id3v2_version 3)
#   - AAC/M4A outputs use -movflags +faststart for reliable container finalization
#   - Encode errors are logged to <output>/.encode.log; 0-byte files are auto-deleted

set -euo pipefail

# -- Defaults ------------------------------------------------------------------

ALL_CODECS="flac,opus,mp3,aac"
ALL_BITRATES="320,256,192,160,128,96,64,48,32"
AUDIO_EXTENSIONS="flac wav aiff aif alac wv"
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
		  generate-permutations.sh -i <input-file-or-dir> [-o <output-dir>] [-c codecs] [-b bitrates]

		Options:
		  -i, --input     Input file or directory (must be lossless: FLAC, WAV, AIFF, ALAC, etc.)
		                  When a directory, all audio files are processed recursively.
		  -o, --output    Output directory (default: current directory)
		  -c, --codecs    Comma-separated codecs (default: flac,opus,mp3,aac)
		  -b, --bitrates  Comma-separated bitrates in kbps (default: 320,256,192,160,128,96,64,48,32)
		  -h, --help      Show this help

		Examples:
		  generate-permutations.sh track.flac
		  generate-permutations.sh -i track.wav -o ./out -c opus,mp3 -b 128,96,64
		  generate-permutations.sh -i ./lossless-tracks/ -o ./out
	USAGE
	exit "${1:-0}"
}

die() {
	echo "Error: $1" >&2
	exit 1
}

warn() {
	echo "Warning: $1" >&2
}

is_lossless() {
	local codec
	codec=$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of csv=p=0 "$1" 2>/dev/null)
	for fmt in $LOSSLESS_FORMATS; do
		[[ "$codec" == "$fmt" ]] && return 0
	done
	return 1
}

# Get a single metadata tag from source (empty if missing)
get_tag() {
	local file="$1" tag="$2"
	ffprobe -v error -show_entries "format_tags=$tag" -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null || echo ""
}

get_artist_tag() {
	get_tag "$1" artist
}

# Parse artist from Bandcamp-style filename: "... - NNN artistname - title.ext"
# Returns artist or empty if pattern doesn't match.
parse_artist_from_filename() {
	local bn="$1"
	local rest="${bn% - *}"
	local artist_part="${rest##* - }"
	if [[ "$artist_part" =~ ^[0-9]+[[:space:]] ]]; then
		echo "$artist_part" | sed -E 's/^[0-9]+[[:space:]]+//'
	else
		echo ""
	fi
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
[[ ! -e "$INPUT" ]] && die "Input '$INPUT' not found"

# Apply defaults
CODECS="${CODECS:-$ALL_CODECS}"
BITRATES="${BITRATES:-$ALL_BITRATES}"

# -- Validate ------------------------------------------------------------------

command -v ffmpeg >/dev/null 2>&1 || die "ffmpeg is required but not found in PATH"
command -v ffprobe >/dev/null 2>&1 || die "ffprobe is required but not found in PATH"

# -- Resolve input files -------------------------------------------------------

INPUT_FILES=()
INPUT_BASE=""

if [[ -d "$INPUT" ]]; then
	INPUT_BASE="$(cd "$INPUT" && pwd)"
	# Build glob pattern for find
	FIND_NAMES=()
	for ext in $AUDIO_EXTENSIONS; do
		FIND_NAMES+=(-o -iname "*.$ext")
	done
	# Remove leading -o
	unset 'FIND_NAMES[0]'

	while IFS= read -r -d '' f; do
		if is_lossless "$f"; then
			INPUT_FILES+=("$f")
		else
			warn "Skipping '$f' -- not a lossless codec"
		fi
	done < <(find "$INPUT_BASE" -type f \( "${FIND_NAMES[@]}" \) -print0 2>/dev/null)

	[[ ${#INPUT_FILES[@]} -eq 0 ]] && die "No lossless audio files found in '$INPUT'"
	echo "Found ${#INPUT_FILES[@]} lossless file(s) in '$INPUT' (recursive)"
elif [[ -f "$INPUT" ]]; then
	if ! is_lossless "$INPUT"; then
		die "Input should be lossless (detected codec: $(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of csv=p=0 "$INPUT" 2>/dev/null || echo 'unknown')). Accepted formats: FLAC, WAV, AIFF, ALAC."
	fi
	INPUT_FILES+=("$(cd "$(dirname "$INPUT")" && pwd)/$(basename "$INPUT")")
else
	die "Input '$INPUT' is neither a file nor a directory"
fi

# -- Setup ---------------------------------------------------------------------

JOBS=$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)
ENCODE_LOG="${OUTPUT}/.encode.log"
FAIL_DIR=$(mktemp -d)
PROGRESS_DIR=$(mktemp -d)
export FAIL_DIR PROGRESS_DIR

# Cleanup on SIGINT/SIGTERM
cleanup_on_signal() {
	echo ""
	echo "Interrupted. Stopping encode jobs..."
	for pid in $(jobs -p 2>/dev/null); do
		kill -TERM "$pid" 2>/dev/null || true
	done
	[[ -n "${PROGRESS_PID:-}" ]] && kill -TERM "$PROGRESS_PID" 2>/dev/null || true
	wait 2>/dev/null || true
	rm -rf "$FAIL_DIR" "$PROGRESS_DIR"
	exit 130
}
trap cleanup_on_signal INT TERM

# Clear previous log
mkdir -p "$OUTPUT"
: >"$ENCODE_LOG"

IFS=',' read -ra CODEC_LIST <<<"$CODECS"
IFS=',' read -ra BITRATE_LIST <<<"$BITRATES"

# Precompute total encodes for progress
TOTAL_ENCODES=0
for _file in "${INPUT_FILES[@]}"; do
	for c in "${CODEC_LIST[@]}"; do
		case "$c" in
		flac) TOTAL_ENCODES=$((TOTAL_ENCODES + 1)) ;;
		opus | mp3 | aac) TOTAL_ENCODES=$((TOTAL_ENCODES + ${#BITRATE_LIST[@]})) ;;
		esac
	done
done

# -- Encode --------------------------------------------------------------------

encode() {
	local input_file="$1" codec="$2" br="$3" ext="$4"
	shift 4
	local extra=("$@") meta_args=()
	local basename
	basename=$(basename "${input_file%.*}")

	# Extract text metadata (strip artwork via -map_metadata -1; artwork duplicated across candidates wastes storage)
	local src_artist src_title src_album
	src_artist=$(get_artist_tag "$input_file" 2>/dev/null || true)
	src_title=$(get_tag "$input_file" title 2>/dev/null || true)
	src_album=$(get_tag "$input_file" album 2>/dev/null || true)

	# Various Artists (Bandcamp): parse artist from filename and override
	if [[ "$src_artist" == "Various Artists" ]]; then
		local parsed
		parsed=$(parse_artist_from_filename "$basename" 2>/dev/null || true)
		[[ -n "$parsed" ]] && src_artist="$parsed"
	fi

	# Re-add text metadata (excludes embedded artwork)
	[[ -n "$src_artist" ]] && meta_args+=(-metadata "artist=$src_artist")
	[[ -n "$src_title" ]] && meta_args+=(-metadata "title=$src_title")
	[[ -n "$src_album" ]] && meta_args+=(-metadata "album=$src_album")

	# Build output dir: {output}/{relative-path}/{codec} or {output}/{codec}
	local outdir
	if [[ -n "$INPUT_BASE" ]]; then
		local dir reldir
		dir=$(dirname "$input_file")
		reldir="${dir#"$INPUT_BASE"}"
		reldir="${reldir#/}"
		if [[ -n "$reldir" ]]; then
			outdir="$OUTPUT/$reldir/$codec"
		else
			outdir="$OUTPUT/$codec"
		fi
	else
		outdir="$OUTPUT/$codec"
	fi

	local outfile="$outdir/${basename}_${codec}_${br}.${ext}"
	mkdir -p "$outdir"
	# -map 0:a: exclude any attached picture stream; -map_metadata -1: strip all metadata (including artwork)
	# then re-add artist/title/album via meta_args
	ffmpeg -y -i "$input_file" -map 0:a -map_metadata -1 "${meta_args[@]}" "${extra[@]}" "$outfile" 2>>"${ENCODE_LOG}"

	# Detect and clean up 0-byte output files (failed encodes)
	if [[ -f "$outfile" && ! -s "$outfile" ]]; then
		warn "0-byte output, encode failed: ${outfile#"$OUTPUT"/} (check ${ENCODE_LOG})"
		rm -f "$outfile"
		touch "${FAIL_DIR}/${codec}_${br}" # marker for parent to count
	fi

	echo . >>"${PROGRESS_DIR}/count"
}

export INPUT_BASE
export PROGRESS_DIR

# -- Process files -------------------------------------------------------------

TOTAL=0
RUNNING=0

# Queue a single encode job in the background.
# When the pool is full, wait for encode jobs to complete.
# Uses plain wait (bash 3.2 compatible). Progress monitor is disowned so wait ignores it.
queue_encode() {
	while ((RUNNING >= JOBS)); do
		wait
		RUNNING=0
	done
	encode "$@" &
	RUNNING=$((RUNNING + 1))
	TOTAL=$((TOTAL + 1))
}

echo "Processing ${#INPUT_FILES[@]} file(s) into '$OUTPUT/' (parallel=$JOBS, $TOTAL_ENCODES encodes)"
echo ""

# Progress monitor: disowned so queue_encode's wait only sees encode jobs
PROGRESS_PID=""
PROGRESS_FILE="${PROGRESS_DIR}/count"
: >"$PROGRESS_FILE"
if ((TOTAL_ENCODES > 0)); then
	(
		prog_file="${PROGRESS_FILE}"
		total=$TOTAL_ENCODES
		while true; do
			done_count=$(($(cat "$prog_file" 2>/dev/null | wc -l) + 0))
			((done_count > total)) && done_count=$total
			pct=$((total > 0 ? done_count * 100 / total : 0))
			printf '\rProgress: %d/%d (%d%%)   ' "$done_count" "$total" "$pct"
			[[ "$done_count" -ge "$total" ]] && break
			sleep 0.25
		done
		echo ""
	) &
	PROGRESS_PID=$!
	disown
fi

for file in "${INPUT_FILES[@]}"; do
	for codec in "${CODEC_LIST[@]}"; do
		case "$codec" in
		flac)
			queue_encode "$file" flac 0 flac -c:a flac
			;;
		opus)
			for br in "${BITRATE_LIST[@]}"; do
				queue_encode "$file" opus "$br" ogg -c:a libopus -b:a "${br}k"
			done
			;;
		mp3)
			for br in "${BITRATE_LIST[@]}"; do
				queue_encode "$file" mp3 "$br" mp3 -c:a libmp3lame -b:a "${br}k" -id3v2_version 3
			done
			;;
		aac)
			for br in "${BITRATE_LIST[@]}"; do
				queue_encode "$file" aac "$br" m4a -c:a aac -b:a "${br}k" -movflags +faststart
			done
			;;
		*)
			warn "Unknown codec '$codec', skipping"
			;;
		esac
	done
done

# Wait for remaining encode jobs, then for progress monitor to finish
wait
[[ -n "$PROGRESS_PID" ]] && wait "$PROGRESS_PID" 2>/dev/null || true

# Count failures from marker files written by background jobs
FAIL_COUNT=$(find "$FAIL_DIR" -type f 2>/dev/null | wc -l | tr -d ' ')
rm -rf "$FAIL_DIR" "$PROGRESS_DIR"

echo ""
if ((FAIL_COUNT > 0)); then
	echo "Done. Generated $((TOTAL - FAIL_COUNT))/$TOTAL files in $OUTPUT/ ($FAIL_COUNT failed — see ${ENCODE_LOG})"
else
	echo "Done. Generated $TOTAL files in $OUTPUT/"
	rm -f "$ENCODE_LOG" # Clean up empty log on success
fi
