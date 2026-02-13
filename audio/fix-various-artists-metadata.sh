#!/usr/bin/env bash
# Fix ARTIST metadata on already-transcoded files when it is "Various Artists".
# Parses the real artist from the filename (Bandcamp pattern: "... - NNN artistname - title")
# and rewrites the metadata in-place without re-encoding (stream copy only).
#
# Usage:
#   ./fix-various-artists-metadata.sh <file-or-dir>
#   ./fix-various-artists-metadata.sh -i <file-or-dir> [--dry-run] [-j N]
#
# Options:
#   -i, --input     File or directory to process (default: positional arg)
#   --dry-run       Show what would be changed without modifying files
#   -j, --jobs      Max parallel jobs (default: CPU count)
#   -h, --help      Show this help
#
# When input is a directory, processes all audio files recursively
# (flac, ogg, mp3, m4a, wav, aiff).

set -euo pipefail

INPUT=""
DRY_RUN=false
JOBS=$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)

usage() {
	cat <<-'USAGE'
		Usage:
		  fix-various-artists-metadata.sh <file-or-dir>
		  fix-various-artists-metadata.sh -i <file-or-dir> [--dry-run]

		Options:
		  -i, --input     File or directory to process
		  --dry-run       Show what would be changed without modifying files
		  -j, --jobs      Max parallel jobs (default: CPU count)
		  -h, --help      Show this help

		Parses artist from Bandcamp-style filenames when ARTIST is "Various Artists"
		and updates the metadata in-place (no re-encoding).
	USAGE
	exit "${1:-0}"
}

die() {
	echo "Error: $1" >&2
	exit 1
}

# Get ARTIST tag from file (empty if missing)
get_artist_tag() {
	ffprobe -v error -show_entries format_tags=artist -of default=noprint_wrappers=1:nokey=1 "$1" 2>/dev/null || echo ""
}

# Strip _codec_bitrate suffix from transcoded basename for parsing
# e.g. "... - 02 antymis - Another System_aac_32" -> "... - 02 antymis - Another System"
strip_encode_suffix() {
	echo "$1" | sed -E 's/_(flac|opus|mp3|aac)_[0-9]+$//'
}

# Parse artist from Bandcamp-style filename: "... - NNN artistname - title"
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

# Queue a single file for processing (runs in background, limits concurrency)
RUNNING=0
queue_process() {
	while ((RUNNING >= JOBS)); do
		wait
		RUNNING=0
	done
	process_file "$1" &
	RUNNING=$((RUNNING + 1))
}

# Process a single file: update ARTIST if Various Artists and parse succeeds
process_file() {
	local file="$1"
	local basename
	basename=$(basename "$file")
	local bn_no_ext="${basename%.*}"

	# Strip _codec_bitrate for transcoded outputs so we get the source-style basename
	local bn_for_parse
	bn_for_parse=$(strip_encode_suffix "$bn_no_ext")

	local src_artist
	src_artist=$(get_artist_tag "$file" 2>/dev/null || true)
	[[ "$src_artist" != "Various Artists" ]] && return 0

	local parsed
	parsed=$(parse_artist_from_filename "$bn_for_parse" 2>/dev/null || true)
	[[ -z "$parsed" ]] && return 0

	# Update metadata: -c copy preserves streams, -metadata overrides artist
	if [[ "$DRY_RUN" == true ]]; then
		echo "Would fix: $file (artist: \"Various Artists\" -> \"$parsed\")"
		return 0
	fi

	local dir base tmp
	dir=$(dirname "$file")
	base=$(basename "$file")
	tmp=$(mktemp -u "${dir}/.fix-metadata-XXXXXX-${base}")
	ffmpeg -y -i "$file" -c copy -metadata "artist=$parsed" "$tmp" 2>/dev/null || {
		rm -f "$tmp"
		die "ffmpeg failed for: $file"
	}
	mv "$tmp" "$file"
	echo "Fixed: $file (artist -> \"$parsed\")"
}

# -- Parse args ----------------------------------------------------------------

while [[ $# -gt 0 ]]; do
	case "$1" in
	-i | --input)
		INPUT="$2"
		shift 2
		;;
	--dry-run)
		DRY_RUN=true
		shift
		;;
	-j | --jobs)
		JOBS="$2"
		shift 2
		;;
	-h | --help)
		usage 0
		;;
	-*)
		die "Unknown option: $1"
		;;
	*)
		[[ -z "$INPUT" ]] && INPUT="$1"
		shift
		;;
	esac
done

[[ -z "$INPUT" ]] && usage 1
[[ ! -e "$INPUT" ]] && die "Input '$INPUT' not found"

command -v ffmpeg >/dev/null 2>&1 || die "ffmpeg is required but not found in PATH"
command -v ffprobe >/dev/null 2>&1 || die "ffprobe is required but not found in PATH"

export DRY_RUN

# -- Process -------------------------------------------------------------------

if [[ -d "$INPUT" ]]; then
	FILES=()
	while IFS= read -r -d '' f; do
		FILES+=("$f")
	done < <(find "$INPUT" -type f \( -iname "*.flac" -o -iname "*.ogg" -o -iname "*.mp3" -o -iname "*.m4a" -o -iname "*.wav" -o -iname "*.aiff" \) -print0 2>/dev/null)
	if [[ ${#FILES[@]} -gt 0 ]]; then
		for f in "${FILES[@]}"; do
			queue_process "$f"
		done
		wait
	fi
else
	process_file "$INPUT"
fi

echo ""
echo "Done."
