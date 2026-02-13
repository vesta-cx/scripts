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
#   Single file input:
#     <output>/{basename}/{codec}_{bitrate}.{ext}
#
#   Directory input:
#     <output>/{relative-path}/{basename}/{codec}_{bitrate}.{ext}
#
#   Example:
#     input: music/jazz/take-five.flac
#     output: out/jazz/take-five/opus_128.ogg
#                                mp3_128.mp3
#                                flac_0.flac
#
# Notes:
#   - FLAC ignores the bitrate list (always outputs as lossless / bitrate=0)
#   - Runs ffmpeg jobs in parallel (one per CPU core)

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

IFS=',' read -ra CODEC_LIST <<<"$CODECS"
IFS=',' read -ra BITRATE_LIST <<<"$BITRATES"

# -- Encode --------------------------------------------------------------------

# Output path: {output}/{relative-path}/{basename}/{codec}_{bitrate}.{ext}
# For single file input: {output}/{basename}/{codec}_{bitrate}.{ext}

encode() {
	local input_file="$1" outdir="$2" codec="$3" br="$4" ext="$5"
	shift 5
	local extra=("$@")
	local outfile="$outdir/${codec}_${br}.${ext}"
	mkdir -p "$outdir"
	echo "Encoding: ${outfile#"$OUTPUT"/}"
	ffmpeg -y -i "$input_file" "${extra[@]}" "$outfile" 2>/dev/null
}

export -f encode
export OUTPUT

# Compute the output subdirectory for a given input file
get_outdir() {
	local file="$1"
	local basename
	basename=$(basename "${file%.*}")

	if [[ -n "$INPUT_BASE" ]]; then
		# Directory mode: mirror relative path
		local dir
		dir=$(dirname "$file")
		local reldir="${dir#"$INPUT_BASE"}"
		reldir="${reldir#/}" # strip leading slash
		if [[ -n "$reldir" ]]; then
			echo "$OUTPUT/$reldir/$basename"
		else
			echo "$OUTPUT/$basename"
		fi
	else
		# Single file mode
		echo "$OUTPUT/$basename"
	fi
}

# Build job list for a single file
build_jobs_for_file() {
	local file="$1"
	local outdir
	outdir=$(get_outdir "$file")

	for codec in "${CODEC_LIST[@]}"; do
		case "$codec" in
		flac)
			echo "$file $outdir flac 0 flac -c:a flac"
			;;
		opus)
			for br in "${BITRATE_LIST[@]}"; do
				echo "$file $outdir opus $br ogg -c:a libopus -b:a ${br}k"
			done
			;;
		mp3)
			for br in "${BITRATE_LIST[@]}"; do
				echo "$file $outdir mp3 $br mp3 -c:a libmp3lame -b:a ${br}k"
			done
			;;
		aac)
			for br in "${BITRATE_LIST[@]}"; do
				echo "$file $outdir aac $br m4a -c:a aac -b:a ${br}k"
			done
			;;
		*)
			warn "Unknown codec '$codec', skipping"
			;;
		esac
	done
}

# Build full job list across all input files
build_all_jobs() {
	for file in "${INPUT_FILES[@]}"; do
		build_jobs_for_file "$file"
	done
}

TOTAL=$(build_all_jobs | wc -l | tr -d ' ')
echo "Generating $TOTAL files into '$OUTPUT/' (parallel=$JOBS)"
echo ""

build_all_jobs | xargs -P "$JOBS" -I {} bash -c 'encode {}'

echo ""
echo "Done. Generated $TOTAL files in $OUTPUT/"
