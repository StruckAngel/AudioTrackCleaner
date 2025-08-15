#!/bin/bash

# Advanced Media Language Filter Script
# Processes MKV and MP4 files to keep only specified language tracks

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Script configuration
SCRIPT_NAME="Media Language Filter"
VERSION="1.0"
LOG_DIR="$HOME/.local/share/media-language-filter/logs"
LOG_FILE="$LOG_DIR/processing-$(date +%Y%m%d_%H%M%S).log"

# Statistics counters
TOTAL_FILES=0
PROCESSED_FILES=0
SKIPPED_FILES=0
ERROR_FILES=0

# Arrays for tracking
declare -a PROCESSED_LIST
declare -a SKIPPED_LIST
declare -a ERROR_LIST

# Function to print colored output
print_status() {
    local status="$1"
    local message="$2"
    case $status in
        "INFO")  echo -e "${BLUE}[INFO]${NC} $message" ;;
        "WARN")  echo -e "${YELLOW}[WARN]${NC} $message" ;;
        "ERROR") echo -e "${RED}[ERROR]${NC} $message" ;;
        "SUCCESS") echo -e "${GREEN}[SUCCESS]${NC} $message" ;;
    esac
}

# Function to log messages
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

# Function to check required packages
check_dependencies() {
    print_status "INFO" "Checking required packages..."
    local missing_packages=()
    
    if ! command -v ffmpeg &> /dev/null; then
        missing_packages+=("ffmpeg")
    fi
    
    if ! command -v ffprobe &> /dev/null; then
        missing_packages+=("ffprobe")
    fi
    
    if [ ${#missing_packages[@]} -ne 0 ]; then
        print_status "ERROR" "Missing required packages: ${missing_packages[*]}"
        echo ""
        echo "Please install the missing packages:"
        echo "Ubuntu/Debian: sudo apt install ffmpeg"
        echo "CentOS/RHEL: sudo yum install ffmpeg"
        echo "macOS: brew install ffmpeg"
        exit 1
    fi
    
    print_status "SUCCESS" "All required packages are installed"
    log_message "Dependency check passed"
}

# Function to create log directory
setup_logging() {
    mkdir -p "$LOG_DIR"
    if [ ! -w "$LOG_DIR" ]; then
        print_status "ERROR" "Cannot write to log directory: $LOG_DIR"
        exit 1
    fi
    
    log_message "=== $SCRIPT_NAME v$VERSION Started ==="
    log_message "Log file: $LOG_FILE"
}

# Function to get user input for languages
get_language_preferences() {
    echo ""
    print_status "INFO" "Language Configuration"
    echo "Enter the languages you want to keep (e.g., eng jpn fre)"
    echo "Use 3-letter ISO 639-2 language codes separated by spaces"
    echo "Common codes: eng (English), jpn (Japanese), fre (French), ger (German), spa (Spanish)"
    read -p "Languages to keep: " KEEP_LANGUAGES
    
    if [ -z "$KEEP_LANGUAGES" ]; then
        print_status "ERROR" "No languages specified. Exiting."
        exit 1
    fi
    
    # Convert to array
    read -ra LANGUAGE_ARRAY <<< "$KEEP_LANGUAGES"
    
    echo ""
    echo "Do you want to set a default language? (y/n)"
    read -p "Choice: " SET_DEFAULT
    
    if [[ $SET_DEFAULT =~ ^[Yy]$ ]]; then
        echo "Available languages: ${LANGUAGE_ARRAY[*]}"
        read -p "Default language: " DEFAULT_LANGUAGE
        
        # Check if default language is in the keep list
        if [[ ! " ${LANGUAGE_ARRAY[*]} " =~ " ${DEFAULT_LANGUAGE} " ]]; then
            print_status "WARN" "Default language not in keep list. No default will be set."
            DEFAULT_LANGUAGE=""
        fi
    fi
    
    log_message "Languages to keep: ${LANGUAGE_ARRAY[*]}"
    log_message "Default language: ${DEFAULT_LANGUAGE:-None}"
}

# Function to get target directory
get_target_directory() {
    echo ""
    print_status "INFO" "Directory Selection"
    read -p "Enter the path to process (e.g., /mnt/pools/media/movies): " TARGET_DIR
    
    if [ ! -d "$TARGET_DIR" ]; then
        print_status "ERROR" "Directory does not exist: $TARGET_DIR"
        exit 1
    fi
    
    if [ ! -r "$TARGET_DIR" ]; then
        print_status "ERROR" "Cannot read directory: $TARGET_DIR"
        exit 1
    fi
    
    log_message "Target directory: $TARGET_DIR"
    print_status "SUCCESS" "Target directory validated: $TARGET_DIR"
}

# Function to analyze audio tracks
analyze_audio_tracks() {
    local file="$1"
    local audio_info
    
    # Get all audio streams with language information
    audio_info=$(ffprobe -v error -select_streams a -show_entries stream=index:stream_tags=language -of csv=p=0 "$file" 2>/dev/null)
    
    if [ -z "$audio_info" ]; then
        return 1
    fi
    
    echo "$audio_info"
    return 0
}

# Function to check if any whitelisted languages exist
has_whitelisted_language() {
    local file="$1"
    local audio_info
    
    audio_info=$(analyze_audio_tracks "$file")
    if [ $? -ne 0 ]; then
        return 1
    fi
    
    while IFS=',' read -r index language; do
        if [ -n "$language" ]; then
            for keep_lang in "${LANGUAGE_ARRAY[@]}"; do
                if [ "$language" = "$keep_lang" ]; then
                    return 0
                fi
            done
        fi
    done <<< "$audio_info"
    
    return 1
}

# Function to process a single file
process_file() {
    local file="$1"
    local filename=$(basename "$file")
    local backup_file="${file}.backup"
    local temp_file="${file}.temp"
    
    print_status "INFO" "Processing: $filename"
    log_message "Processing file: $file"
    
    # Check if file has whitelisted languages
    if ! has_whitelisted_language "$file"; then
        print_status "WARN" "No whitelisted languages found in $filename - skipping"
        log_message "SKIPPED: No whitelisted languages in $file"
        SKIPPED_LIST+=("$file: No whitelisted languages")
        ((SKIPPED_FILES++))
        return 0
    fi
    
    # Create backup
    if ! cp "$file" "$backup_file"; then
        print_status "ERROR" "Failed to create backup for $filename"
        log_message "ERROR: Failed to create backup for $file"
        ERROR_LIST+=("$file: Backup creation failed")
        ((ERROR_FILES++))
        return 1
    fi
    
    # Build ffmpeg command
    local ffmpeg_cmd="ffmpeg -i \"$file\" -map 0:v -c:v copy"
    local audio_mapped=false
    local default_set=false
    local audio_index=0
    
    # Get audio track information
    local audio_info
    audio_info=$(analyze_audio_tracks "$file")
    
    # Map whitelisted audio tracks
    while IFS=',' read -r index language; do
        if [ -n "$language" ]; then
            for keep_lang in "${LANGUAGE_ARRAY[@]}"; do
                if [ "$language" = "$keep_lang" ]; then
                    ffmpeg_cmd+=" -map 0:a:$((index))"
                    audio_mapped=true
                    
                    # Set default if this is the preferred language and no default is set yet
                    if [ -n "$DEFAULT_LANGUAGE" ] && [ "$language" = "$DEFAULT_LANGUAGE" ] && [ "$default_set" = false ]; then
                        ffmpeg_cmd+=" -disposition:a:$audio_index default"
                        default_set=true
                    else
                        ffmpeg_cmd+=" -disposition:a:$audio_index 0"
                    fi
                    
                    ((audio_index++))
                    break
                fi
            done
        fi
    done <<< "$audio_info"
    
    # If no audio was mapped, skip processing
    if [ "$audio_mapped" = false ]; then
        print_status "WARN" "No audio tracks to map for $filename - skipping"
        rm -f "$backup_file"
        log_message "SKIPPED: No audio tracks to map for $file"
        SKIPPED_LIST+=("$file: No audio tracks to map")
        ((SKIPPED_FILES++))
        return 0
    fi
    
    # Add remaining options
    ffmpeg_cmd+=" -c:a copy -map 0:s? -c:s copy -y \"$temp_file\""
    
    # Execute ffmpeg command
    log_message "FFmpeg command: $ffmpeg_cmd"
    if eval $ffmpeg_cmd > /dev/null 2>&1; then
        # Replace original file with processed file
        if mv "$temp_file" "$file"; then
            rm -f "$backup_file"
            print_status "SUCCESS" "Successfully processed $filename"
            log_message "SUCCESS: Processed $file"
            PROCESSED_LIST+=("$file")
            ((PROCESSED_FILES++))
        else
            print_status "ERROR" "Failed to replace original file $filename"
            mv "$backup_file" "$file" 2>/dev/null
            rm -f "$temp_file"
            log_message "ERROR: Failed to replace original file $file"
            ERROR_LIST+=("$file: Failed to replace original")
            ((ERROR_FILES++))
        fi
    else
        print_status "ERROR" "FFmpeg processing failed for $filename"
        mv "$backup_file" "$file" 2>/dev/null
        rm -f "$temp_file"
        log_message "ERROR: FFmpeg processing failed for $file"
        ERROR_LIST+=("$file: FFmpeg processing failed")
        ((ERROR_FILES++))
    fi
}

# Function to find and process all media files
process_directory() {
    print_status "INFO" "Scanning directory: $TARGET_DIR"
    log_message "Starting directory scan"
    
    # Find all MKV and MP4 files recursively
    while IFS= read -r -d '' file; do
        ((TOTAL_FILES++))
        process_file "$file"
    done < <(find "$TARGET_DIR" -type f \( -iname "*.mkv" -o -iname "*.mp4" \) -print0)
}

# Function to generate final report
generate_report() {
    echo ""
    print_status "INFO" "=== PROCESSING COMPLETE ==="
    echo ""
    
    print_status "INFO" "Statistics:"
    echo "  Total files found: $TOTAL_FILES"
    echo "  Successfully processed: $PROCESSED_FILES"
    echo "  Skipped: $SKIPPED_FILES"
    echo "  Errors: $ERROR_FILES"
    echo ""
    
    # Log detailed results
    log_message "=== PROCESSING SUMMARY ==="
    log_message "Total files: $TOTAL_FILES"
    log_message "Processed: $PROCESSED_FILES"
    log_message "Skipped: $SKIPPED_FILES"
    log_message "Errors: $ERROR_FILES"
    log_message ""
    
    # Log processed files
    if [ ${#PROCESSED_LIST[@]} -gt 0 ]; then
        log_message "SUCCESSFULLY PROCESSED FILES:"
        for file in "${PROCESSED_LIST[@]}"; do
            log_message "  - $file"
        done
        log_message ""
    fi
    
    # Log skipped files
    if [ ${#SKIPPED_LIST[@]} -gt 0 ]; then
        log_message "SKIPPED FILES:"
        for entry in "${SKIPPED_LIST[@]}"; do
            log_message "  - $entry"
        done
        log_message ""
    fi
    
    # Log error files
    if [ ${#ERROR_LIST[@]} -gt 0 ]; then
        log_message "ERROR FILES:"
        for entry in "${ERROR_LIST[@]}"; do
            log_message "  - $entry"
        done
        log_message ""
    fi
    
    print_status "INFO" "Full log saved to: $LOG_FILE"
    log_message "=== $SCRIPT_NAME Processing Complete ==="
}

# Main execution
main() {
    echo "=== $SCRIPT_NAME v$VERSION ==="
    echo ""
    
    # Check dependencies
    check_dependencies
    
    # Setup logging
    setup_logging
    
    # Get user preferences
    get_language_preferences
    get_target_directory
    
    # Confirm before processing
    echo ""
    print_status "INFO" "Configuration Summary:"
    echo "  Target Directory: $TARGET_DIR"
    echo "  Languages to Keep: ${LANGUAGE_ARRAY[*]}"
    echo "  Default Language: ${DEFAULT_LANGUAGE:-None}"
    echo "  Log File: $LOG_FILE"
    echo ""
    
    read -p "Proceed with processing? (y/n): " CONFIRM
    if [[ ! $CONFIRM =~ ^[Yy]$ ]]; then
        print_status "INFO" "Processing cancelled by user"
        exit 0
    fi
    
    # Process files
    echo ""
    process_directory
    
    # Generate report
    generate_report
}

# Run main function
main "$@"
